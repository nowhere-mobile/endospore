#!/usr/bin/env bash
# run.sh <StoreInstaller.java> -- NWP-20261120-18: lift the session-presence receipt members (stampFor,
# snapshotAppSeen, noteAppGone, appGoneThisSession, appSeenThisSession, stampMatches, readSeenLines), the two file
# names, APPKEEP_LOCK, the AtomicIo seam, FILE_IO and both writeAtomic overloads out of StoreInstaller.java, by
# signature, and run Cases against them under plain javac/java with a Context and a Log stub. seenStamp needs a
# UserManager and is stubbed as stampFor(ctx.serial), so the stampFor that runs is the shipped one. $JAVAC / $JAVA
# come from the caller (core/chooser/test-presence-receipt-java.sh), which also sets $W, the one temp root.
#
# Exit codes: 1 = a case failed; 2 = a member did not extract; 3 = the lifted classes or the cases did not compile.
set -euo pipefail
SI="${1:?usage: run.sh path/to/StoreInstaller.java}"
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
ONE=("    static final Object APPKEEP_LOCK = "
     "    private static final String SEEN_FILE = "
     "    private static final String GONE_FILE = ")
BLOCKS=("    interface AtomicIo {"
        "    static void writeAtomic(File f, String content) throws "
        "    static void writeAtomic(File f, String content, AtomicIo io) throws "
        "    static String stampFor(long serial) {"
        "    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {"
        "    static void noteAppGone(Context ctx, String pkg) {"
        "    static java.util.Set<String> appGoneThisSession(Context ctx) {"
        "    static java.util.Set<String> appSeenThisSession(Context ctx) {"
        "    private static boolean stampMatches(File f, String want) {"
        "    private static java.util.Set<String> readSeenLines(File f) {")
FILE_IO="    static final AtomicIo FILE_IO = "
STUB="    private static String seenStamp(Context ctx) { return stampFor(ctx.serial); }"
{
  echo "import android.content.Context;"
  echo "import android.util.Log;"
  echo "import java.io.File;"
  echo "final class StoreInstaller {"
  for p in "${ONE[@]}"; do one_line "$SI" "$p"; done
  for p in "${BLOCKS[@]}"; do brace_block "$SI" "$p"; done
  awk -v sig="$FILE_IO" '!on && index($0, sig) == 1 { on=1 } on { print } on && $0 == "    };" { exit }' "$SI"
  echo "$STUB"
  echo "}"
} > "$D/StoreInstaller.java"
for piece in "${ONE[@]}" "${BLOCKS[@]}" "$FILE_IO" "$STUB"; do
  [ "$(grep -cF -- "$piece" "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
[ "$(grep -c '^    };$' "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: FILE_IO's end" >&2; exit 2; }
# a lifted block that is only its signature line is an anchor that matched but never closed
[ "$(grep -c . "$D/StoreInstaller.java")" -gt 90 ] || { echo "EXTRACTION FAILED: StoreInstaller is too short" >&2; exit 2; }
cp "$here/Cases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/StoreInstaller.java" "$D/Cases.java" $(find "$here/stubs" -name '*.java') || exit 3
mkdir "$D/cases"
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" Cases "$D/cases" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
