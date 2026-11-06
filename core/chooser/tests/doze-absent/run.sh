#!/usr/bin/env bash
# run.sh <DozeAppsMirror.java> -- NWP-20261104-16: lift keptPackages and absentKept out of DozeAppsMirror.java by
# signature and run DozeAbsentCases against them under plain javac/java. Both use only java.io and java.util, so no
# stubs. $JAVAC / $JAVA come from the caller (core/vendor-common/bin/test-doze-absent-java.sh), which also sets $W,
# the one temp root.
#
# Exit codes: 1 = a case failed; 2 = a member did not extract; 3 = the lifted class or the cases did not compile.
set -euo pipefail
DM="${1:?usage: run.sh path/to/DozeAppsMirror.java}"
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
SIG_KEPT="    static java.util.Set<String> keptPackages(java.io.File keep) {"
SIG_ABS="    static java.util.Set<String> absentKept(java.util.Set<String> installed, java.util.List<String> recorded,"
{
  echo "final class DozeAppsMirror {"
  brace_block "$DM" "$SIG_KEPT"
  brace_block "$DM" "$SIG_ABS"
  echo "}"
} > "$D/DozeAppsMirror.java"
for piece in "$SIG_KEPT" "$SIG_ABS"; do
  [ "$(grep -cF -- "$piece" "$D/DozeAppsMirror.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
# a lifted block that is only its signature line is an anchor that matched but never closed
[ "$(grep -c . "$D/DozeAppsMirror.java")" -gt 20 ] || { echo "EXTRACTION FAILED: DozeAppsMirror is too short" >&2; exit 2; }
cp "$here/DozeAbsentCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/DozeAppsMirror.java" "$D/DozeAbsentCases.java" || exit 3
mkdir "$D/cases"
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" DozeAbsentCases "$D/cases" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
