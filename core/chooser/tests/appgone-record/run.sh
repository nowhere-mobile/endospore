#!/usr/bin/env bash
# run.sh <ProfileActivity.java> <StoreInstaller.java> -- NWP-20261023-10: lift recordUninstalled, readUninstalled,
# clearUninstalled (and the strict reader they share), APPKEEP_LOCK, the AtomicIo seam, FILE_IO and both writeAtomic
# overloads out of StoreInstaller.java, and keepSetAll out of ProfileActivity.java, by signature, and run
# AppgoneRecordCases against them under plain javac/java with a Context and a Log stub. $JAVAC / $JAVA come from the
# caller (core/chooser/test-appgone-record-java.sh), which also sets $W, the one temp root.
#
# Exit codes: 1 = a case failed; 2 = a member did not extract; 3 = the lifted classes or the cases did not compile.
set -euo pipefail
PA="${1:?usage: run.sh path/to/ProfileActivity.java path/to/StoreInstaller.java}"
SI="${2:?usage: run.sh path/to/ProfileActivity.java path/to/StoreInstaller.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${W:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT
# brace_block <file> <signature prefix>: from the line that starts with it to the brace that closes it
brace_block() {
  awk -v sig="$2" '
    !on && index($0, sig) == 1 { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
one_line() { awk -v sig="$2" 'index($0, sig) == 1 { print; exit }' "$1"; }
SIG_KSA="    static java.util.Set<String> keepSetAll(android.content.Context ctx) {"
SIG_LOCK="    static final Object APPKEEP_LOCK = "
SIG_REC="    static void recordUninstalled(Context ctx, "
SIG_RD="    static java.util.LinkedHashSet<String> readUninstalled(Context ctx) {"
SIG_CLR="    static void clearUninstalled(Context ctx, "
SIG_LINES="    private static java.util.LinkedHashSet<String> uninstalledLines("
{
  echo "final class ProfileActivity {"
  brace_block "$PA" "$SIG_KSA"
  echo "}"
} > "$D/ProfileActivity.java"
{
  echo "import android.content.Context;"
  echo "import android.util.Log;"
  echo "import java.io.File;"
  echo "final class StoreInstaller {"
  one_line "$SI" "$SIG_LOCK"
  brace_block "$SI" "    interface AtomicIo {"
  awk '!on && index($0, "    static final AtomicIo FILE_IO = ") == 1 { on=1 } on { print } on && $0 == "    };" { exit }' "$SI"
  brace_block "$SI" "    static void writeAtomic(File f, String content) throws "
  brace_block "$SI" "    static void writeAtomic(File f, String content, AtomicIo io) throws "
  brace_block "$SI" "$SIG_REC"
  brace_block "$SI" "$SIG_RD"
  brace_block "$SI" "$SIG_CLR"
  brace_block "$SI" "$SIG_LINES"
  echo "}"
} > "$D/StoreInstaller.java"
[ "$(grep -cF -- "$SIG_KSA" "$D/ProfileActivity.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $SIG_KSA" >&2; exit 2; }
for piece in "$SIG_LOCK" "    interface AtomicIo {" "    static final AtomicIo FILE_IO = " \
             "    static void writeAtomic(File f, String content) throws " \
             "    static void writeAtomic(File f, String content, AtomicIo io) throws " \
             "$SIG_REC" "$SIG_RD" "$SIG_CLR" "$SIG_LINES"; do
  [ "$(grep -cF -- "$piece" "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
[ "$(grep -c '^    };$' "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: FILE_IO's end" >&2; exit 2; }
# a lifted block that is only its signature line is an anchor that matched but never closed
[ "$(grep -c . "$D/ProfileActivity.java")" -gt 6 ] || { echo "EXTRACTION FAILED: ProfileActivity is too short" >&2; exit 2; }
[ "$(grep -c . "$D/StoreInstaller.java")" -gt 60 ] || { echo "EXTRACTION FAILED: StoreInstaller is too short" >&2; exit 2; }
cp "$here/AppgoneRecordCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/ProfileActivity.java" "$D/StoreInstaller.java" "$D/AppgoneRecordCases.java" \
  $(find "$here/stubs" -name '*.java') || exit 3
mkdir "$D/cases"
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" AppgoneRecordCases "$D/cases" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
