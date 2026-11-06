#!/usr/bin/env bash
# run.sh <SafeEdit.java> -- NWP-20261114-21: lift pasteAllowed out of SafeEdit.java by signature and run Cases
# against it under plain javac/java. It is pure boolean logic, so no stubs. $JAVAC / $JAVA come from the caller
# (core/vendor-common/bin/test-safe-edit-paste-java.sh), which also sets $W, the one temp root.
#
# Exit codes: 1 = a case failed; 2 = the member did not extract; 3 = the lifted class or the cases did not compile.
set -euo pipefail
SE="${1:?usage: run.sh path/to/SafeEdit.java}"
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
SIG='    static boolean pasteAllowed(boolean pasteWanted, boolean clipboardReachable) {'
[ "$(grep -cF -- "$SIG" "$SE" || true)" = 1 ] || { echo "EXTRACTION FAILED: $SIG is not in $SE exactly once" >&2; exit 2; }
{
  echo "final class SafeEdit {"
  brace_block "$SE" "$SIG"
  echo "}"
} > "$D/SafeEdit.java"
# a lifted block that is only its signature line is an anchor that matched but never closed
[ "$(grep -c . "$D/SafeEdit.java")" -ge 5 ] || { echo "EXTRACTION FAILED: pasteAllowed is too short" >&2; exit 2; }
cp "$here/Cases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/SafeEdit.java" "$D/Cases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" Cases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
