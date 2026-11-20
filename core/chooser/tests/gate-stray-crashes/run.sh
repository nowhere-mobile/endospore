#!/usr/bin/env bash
# run.sh <core/chooser dir> -- NWP-20261210-24: lift GateStrayCrashes's pure members (CAL, MEDIA, process, code,
# userState, bucket, tally; java.lang/java.util only) into a plain class, beside a CrashRecords fixture that holds the
# REAL CrashRecords.AID_USER and CrashRecords.headerUid, and run GateStrayCrashesCases against them and against the
# source of the reads that cannot run without Android.
# JAVAC and JAVA name the tools (default: javac, java on PATH); core/vendor-common/bin/test-gate-stray-crashes-java.sh
# resolves them and is what CI runs. Temps go under $W when the driver exports it, else under a root of this run's own.
# Exit status: 0 every case passed; 1 a case or pin failed; 2 cannot run (a tool, a file or a member missing);
# 3 the lifted members do not compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
SRC="$J/GateStrayCrashes.java"
CR="$J/CrashRecords.java"
for f in "$SRC" "$CR" "$J/ChooserActivity.java" "$here/GateStrayCrashesCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
if [ -n "${W:-}" ] && [ -d "$W" ]; then
  D=$(mktemp -d -p "$W") || exit 2
else
  W=$(mktemp -d) || exit 2
  trap 'rm -rf "$W"' EXIT
  D=$(mktemp -d -p "$W") || exit 2
fi
# lift <method> <file>: from the method's declaration ('static', then its name and '(' -- never a call site) to the
# brace closing it, with any access modifier dropped.
lift() {
  awk -v m="$1" '
    !on && $0 ~ ("^[ \t]*(private |public )?static [^=;]* " m "[(]") { on=1; depth=0 }
    on { print; n=gsub(/[{]/,"{"); c=gsub(/[}]/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$2" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
}
# konst <name> <file>: the one-line 'static final <type> <name> = ...;' declaration.
konst() { grep -E "^[ \t]*static final [A-Za-z]+ $1 = [^;]*;" "$2" | head -n 1; }
members="process code userState bucket tally"
{
  echo "import java.util.LinkedHashMap;"
  echo "import java.util.Set;"
  echo "final class GateStrayCrashes {"
  konst CAL "$SRC"; konst MEDIA "$SRC"
  for k in $members; do lift "$k" "$SRC"; done
  echo "}"
} > "$D/GateStrayCrashes.java"
{
  echo "final class CrashRecords {"
  konst AID_USER "$CR"
  lift headerUid "$CR"
  echo "}"
} > "$D/CrashRecords.java"
for k in $members; do
  n=$(grep -cE "^[ \t]*static [^=;]* $k[(]" "$D/GateStrayCrashes.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: member $k found $n time(s), want 1" >&2; exit 2; }
done
for k in CAL MEDIA; do
  n=$(grep -cE "^[ \t]*static final String $k = " "$D/GateStrayCrashes.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: constant $k found $n time(s), want 1" >&2; exit 2; }
done
n=$(grep -cE "^[ \t]*static (final int AID_USER = |int headerUid[(])" "$D/CrashRecords.java" || true)
[ "$n" = 2 ] || { echo "run.sh: CrashRecords.AID_USER or headerUid not found" >&2; exit 2; }
cp "$here/GateStrayCrashesCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/GateStrayCrashes.java" "$D/CrashRecords.java" "$D/GateStrayCrashesCases.java" \
  || { echo "run.sh: the lifted members do not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$W" -cp "$D" GateStrayCrashesCases "$J"
