#!/usr/bin/env bash
# run.sh <StoreInstaller.java> <GosState.java> <AppClaim.java> -- NWP-20261022-06: lift writeAtomic (and its AtomicIo
# seam), GosState.write and AppClaim.writeReceipt (four arguments) out of the real sources by signature, into scratch
# classes, and run FallbackCases against them under plain javac/java. The scratch StoreInstaller declares its OWN
# non-final FILE_IO, a seam the cases make fail; the real constant is not lifted. $JAVAC / $JAVA come from the caller
# (core/chooser/test-no-truncating-fallback-java.sh), which also sets $W, the one temp root.
#
# Exit codes: 1 = a case or a source pin failed; 2 = a member did not extract; 3 = the lifted classes or the cases did
# not compile.
set -euo pipefail
STORE="${1:?usage: run.sh StoreInstaller.java GosState.java AppClaim.java}"
GOS="${2:?usage: run.sh StoreInstaller.java GosState.java AppClaim.java}"
AC="${3:?usage: run.sh StoreInstaller.java GosState.java AppClaim.java}"
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
SIG_IFACE="    interface AtomicIo {"
SIG_W1="    static void writeAtomic(File f, String content) throws "
SIG_W2="    static void writeAtomic(File f, String content, AtomicIo io) throws "
SIG_GOS="    private static void write(File f, String content) {"
SIG_RF="    private static File receiptFile(Context ctx) {"
SIG_WR="    private static void writeReceipt(Context ctx, int userId, java.util.Set<String> pkgs, String why) {"

cat > "$D/Stubs.java" <<'JAVA'
import java.io.File;
class Log {
    static int warned;
    static void w(String t, String m, Throwable e) { warned++; System.out.println("  log: " + m + ": " + e); }
    static void w(String t, String m) { warned++; }
}
class Context {
    final File dir;
    Context(File d) { dir = d; }
    File getFilesDir() { return dir; }
}
JAVA
{
  echo "import java.io.File;"
  echo "final class StoreInstaller {"
  brace_block "$STORE" "$SIG_IFACE"
  echo "    static AtomicIo FILE_IO; // test-installed seam (FallbackCases.Seam), not the real constant"
  brace_block "$STORE" "$SIG_W1"
  brace_block "$STORE" "$SIG_W2"
  echo "}"
} > "$D/StoreInstaller.java"
{
  echo "import java.io.File;"
  echo "final class GosState {"
  brace_block "$GOS" "$SIG_GOS" | sed 's/^    private static /    static /'
  echo "}"
} > "$D/GosState.java"
{
  echo "import java.io.File;"
  echo "final class AppClaim {"
  sed -n 's/^    private static final String \(RECEIPT\|TAG\) = /    static final String \1 = /p' "$AC"
  { brace_block "$AC" "$SIG_RF"; brace_block "$AC" "$SIG_WR"; } | sed 's/^    private static /    static /'
  echo "}"
} > "$D/AppClaim.java"
want() { # want <file> <fixed string> <count>
  [ "$(grep -cF -- "$2" "$1" || true)" = "$3" ] || { echo "EXTRACTION FAILED: $2" >&2; exit 2; }
}
want "$D/StoreInstaller.java" "$SIG_IFACE" 1
want "$D/StoreInstaller.java" "$SIG_W1" 1
want "$D/StoreInstaller.java" "$SIG_W2" 1
want "$D/StoreInstaller.java" "static final AtomicIo FILE_IO" 0
want "$D/GosState.java" "    static void write(File f, String content) {" 1
want "$D/AppClaim.java" "    static final String RECEIPT = " 1
want "$D/AppClaim.java" "    static final String TAG = " 1
want "$D/AppClaim.java" "    static File receiptFile(Context ctx) {" 1
want "$D/AppClaim.java" "    static void writeReceipt(Context ctx, int userId, java.util.Set<String> pkgs, String why) {" 1

# (e) source pins, on the two method bodies with their comments stripped
pins=0
pin() { # pin <label> <scratch file> <signature prefix>
  local text n_w n_r n_f
  text=$(brace_block "$2" "$3" | perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g')
  n_w=$(printf '%s' "$text" | grep -o -F 'StoreInstaller.writeAtomic(' | wc -l || true)
  n_r=$(printf '%s' "$text" | grep -o -F 'renameTo(' | wc -l || true)
  n_f=$(printf '%s' "$text" | grep -o -F 'new java.io.FileWriter(' | wc -l || true)
  [ "$n_w" -eq 1 ] || { echo "FAIL (e) $1: $n_w StoreInstaller.writeAtomic( calls, want exactly 1"; pins=1; }
  [ "$n_r" -eq 0 ] || { echo "FAIL (e) $1: renameTo( appears $n_r time(s)"; pins=1; }
  [ "$n_f" -eq 0 ] || { echo "FAIL (e) $1: new java.io.FileWriter( appears $n_f time(s)"; pins=1; }
}
pin GosState.write "$D/GosState.java" "    static void write(File f, String content) {"
pin AppClaim.writeReceipt "$D/AppClaim.java" "    static void writeReceipt(Context ctx, int userId, java.util.Set<String> pkgs, String why) {"

cp "$here/FallbackCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D"/*.java || exit 3
mkdir "$D/cases"
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" FallbackCases "$D/cases" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
[ "$rc" = 0 ] && [ "$pins" = 0 ] || exit 1
exit 0
