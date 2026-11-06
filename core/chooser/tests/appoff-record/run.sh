#!/usr/bin/env bash
# run.sh <ProfileActivity.java> <StoreInstaller.java> -- NWP-20261025-06: lift recordTurnedOff, clearTurnedOff, the raw
# reader turnedOffLinesRaw, clearUninstalled (and the strict reader it shares), APPKEEP_LOCK, the AtomicIo seam,
# FILE_IO and both writeAtomic overloads out of StoreInstaller.java, and keepSetAll, explicitlyTurnedOff and the three
# *_PKG constants out of ProfileActivity.java, by signature, and run AppoffRecordCases against them under plain
# javac/java with a Context and a Log stub. $JAVAC / $JAVA come from the caller (core/chooser/test-appoff-record-java.sh),
# which also sets $W, the one temp root.
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
SIG_EXP="    static java.util.LinkedHashSet<String> explicitlyTurnedOff(android.content.Context ctx) {"
SIG_GMS="    static final String GMS_PKG = "
SIG_GSF="    static final String GSF_PKG = "
SIG_VEN="    static final String VENDING_PKG = "
SIG_LOCK="    static final Object APPKEEP_LOCK = "
SIG_RTO="    static void recordTurnedOff(Context ctx, String pkg) {"
SIG_CTO="    static void clearTurnedOff(Context ctx, java.util.Collection<String> pkgs) {"
SIG_RAW="    private static java.util.LinkedHashSet<String> turnedOffLinesRaw("
SIG_CLR="    static void clearUninstalled(Context ctx, "
SIG_LINES="    private static java.util.LinkedHashSet<String> uninstalledLines("
{
  echo "final class ProfileActivity {"
  one_line "$PA" "$SIG_GMS"
  one_line "$PA" "$SIG_GSF"
  one_line "$PA" "$SIG_VEN"
  brace_block "$PA" "$SIG_KSA"
  brace_block "$PA" "$SIG_EXP"
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
  brace_block "$SI" "$SIG_RTO"
  brace_block "$SI" "$SIG_CTO"
  brace_block "$SI" "$SIG_RAW"
  brace_block "$SI" "$SIG_CLR"
  brace_block "$SI" "$SIG_LINES"
  echo "}"
} > "$D/StoreInstaller.java"
for piece in "$SIG_KSA" "$SIG_EXP" "$SIG_GMS" "$SIG_GSF" "$SIG_VEN"; do
  [ "$(grep -cF -- "$piece" "$D/ProfileActivity.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
for piece in "$SIG_LOCK" "    interface AtomicIo {" "    static final AtomicIo FILE_IO = " \
             "    static void writeAtomic(File f, String content) throws " \
             "    static void writeAtomic(File f, String content, AtomicIo io) throws " \
             "$SIG_RTO" "$SIG_CTO" "$SIG_RAW" "$SIG_CLR" "$SIG_LINES"; do
  [ "$(grep -cF -- "$piece" "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
[ "$(grep -c '^    };$' "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: FILE_IO's end" >&2; exit 2; }
# a lifted block that is only its signature line is an anchor that matched but never closed
[ "$(grep -c . "$D/ProfileActivity.java")" -gt 20 ] || { echo "EXTRACTION FAILED: ProfileActivity is too short" >&2; exit 2; }
[ "$(grep -c . "$D/StoreInstaller.java")" -gt 80 ] || { echo "EXTRACTION FAILED: StoreInstaller is too short" >&2; exit 2; }
cp "$here/AppoffRecordCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/ProfileActivity.java" "$D/StoreInstaller.java" "$D/AppoffRecordCases.java" \
  $(find "$here/stubs" -name '*.java') || exit 3
mkdir "$D/cases"
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" AppoffRecordCases "$D/cases" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
