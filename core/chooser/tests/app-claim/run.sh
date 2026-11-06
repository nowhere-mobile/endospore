#!/usr/bin/env bash
# run.sh <core/chooser dir> -- NWP-20261015-27: lift AppClaim's pure claim-record reader, receipt reader and hold/release
# diff (readClaims, readClaimsFile, parseClaims, claimedElsewhere, parseReceipt, readReceiptFile, diff) into a plain
# class and run AppClaimCases against it (NWP-20261111-16 added readReceiptFile, the strict receipt reader;
# NWP-20261125-06 added parseClaimNames, readClaimNames and holdGroups, the holder's name per hold). Only
# android.content.Context (getFilesDir) and android.util.Log (w) are stubbed. JAVAC and
# JAVA name the tools; core/vendor-common/bin/test-app-claim-java.sh resolves them and is what CI runs. Exit status:
# 0 every case passed; 1 a case failed; 2 cannot run (a tool, a file or a helper missing); 3 the lifted helpers do not
# compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
AC="$CH/src/com/nowhere/chooser/AppClaim.java"
for f in "$AC" "$here/AppClaimCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
# Every temp of this run, java.io.tmpdir included, lives inside $D.
D=$(mktemp -d) || exit 2
trap 'rm -rf "$D"' EXIT
lift(){ # lift <name>: every static method of that name, declaration to its closing brace, minus the access modifier
  awk -v name="$1" '
    !on && $0 ~ "^[ \t]*(private |public )?static [^=;]* " name "[(]" { on=1; depth=0 }
    on { print; n=gsub(/[{]/,"{"); c=gsub(/[}]/,"}"); depth+=n-c; if (depth==0 && n+c>0) { on=0; print "" } }
  ' "$AC" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
}
{
  echo "import java.io.File;"
  echo "final class Lifted {"
  echo "  static final String TAG = \"NowhereChooser\";"
  sed -n 's/^    private static final String CLAIMS = \(.*\)$/  static final String CLAIMS = \1/p' "$AC"
  echo "  static class Context { File dir; File getFilesDir() { return dir; } }"
  echo "  static class Log { static void w(String t, String m) {} static void w(String t, String m, Throwable e) {} }"
  for m in readClaims readClaimsFile parseClaims claimedElsewhere parseReceipt readReceiptFile diff parseClaimNames readClaimNames holdGroups; do lift "$m"; done
  echo "}"
} > "$D/Lifted.java"
for m in readClaims readClaimsFile parseClaims claimedElsewhere readReceiptFile diff parseClaimNames readClaimNames holdGroups; do
  n=$(grep -cE "^[ \t]*static [^=;]* $m[(]" "$D/Lifted.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: helper $m found $n time(s), want 1" >&2; exit 2; }
done
n=$(grep -cE "^[ \t]*static [^=;]* parseReceipt[(]" "$D/Lifted.java" || true)
[ "$n" = 2 ] || { echo "run.sh: helper parseReceipt found $n time(s), want 2" >&2; exit 2; }
grep -q 'CLAIMS = "nowhere-claims"' "$D/Lifted.java" || { echo "run.sh: CLAIMS constant not found" >&2; exit 2; }
cp "$here/AppClaimCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/AppClaimCases.java" || { echo "run.sh: the lifted helpers do not compile" >&2; exit 3; }
# java.io.tmpdir is /tmp whatever TMPDIR says: point it at $D.
"$JAVA" -Dfile.encoding=UTF-8 -Djava.io.tmpdir="$D" -cp "$D" AppClaimCases "$AC"
