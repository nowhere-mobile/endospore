#!/usr/bin/env bash
# run.sh <StoreInstaller.java> -- NWP-20261021-06: lift the AtomicIo seam, FILE_IO and both writeAtomic overloads
# verbatim out of StoreInstaller.java by signature, and run WriteAtomicCases against them under plain javac/java. They
# use only java.io, so the class compiles with no Android SDK. $JAVAC / $JAVA come from the caller
# (core/chooser/test-write-atomic-java.sh), which also sets $W, the one temp root.
#
# Exit codes: 1 = a case failed; 2 = a member did not extract; 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/StoreInstaller.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${W:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT
# brace_block <signature prefix>: from the line that starts with it to the brace that closes it
brace_block() {
  awk -v sig="$1" '
    !on && index($0, sig) == 1 { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$SRC"
}
{
  echo "import java.io.File;"
  echo "final class StoreInstaller {"
  brace_block "    interface AtomicIo {"
  # FILE_IO is an anonymous class: from its declaration to the line that closes it
  awk '!on && index($0, "    static final AtomicIo FILE_IO = ") == 1 { on=1 } on { print } on && $0 == "    };" { exit }' "$SRC"
  brace_block "    static void writeAtomic(File f, String content) throws "
  brace_block "    static void writeAtomic(File f, String content, AtomicIo io) throws "
  echo "}"
} > "$D/StoreInstaller.java"
for piece in "    interface AtomicIo {" "    static final AtomicIo FILE_IO = " \
             "    static void writeAtomic(File f, String content) throws " \
             "    static void writeAtomic(File f, String content, AtomicIo io) throws "; do
  [ "$(grep -cF -- "$piece" "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
[ "$(grep -c '^    };$' "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: FILE_IO's end" >&2; exit 2; }
cp "$here/WriteAtomicCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/StoreInstaller.java" "$D/WriteAtomicCases.java" || exit 3
mkdir "$D/cases"
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" WriteAtomicCases "$D/cases" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
