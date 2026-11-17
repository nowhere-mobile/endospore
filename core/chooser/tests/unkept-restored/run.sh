#!/usr/bin/env bash
# run.sh <UnkeptRestored.java> -- NWP-20261203-24: compile UnkeptRestored with UnkeptRestoredCases under plain
# javac/java and run the cases. $JAVAC / $JAVA come from the caller (core/chooser/test-unkept-restored-java.sh),
# which also sets $W, the one temp root.
#
# Exit codes: 1 = a case failed; 2 = the input is missing; 3 = the classes did not compile.
set -euo pipefail
UR="${1:?usage: run.sh path/to/UnkeptRestored.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$UR" ] || { echo "MISSING: $UR" >&2; exit 2; }
D=$(mktemp -d -p "${W:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$UR" "$D/src/com/nowhere/chooser/UnkeptRestored.java"
cp "$here/UnkeptRestoredCases.java" "$D/src/com/nowhere/chooser/"
"$JAVAC" -encoding UTF-8 -d "$D/out" "$D/src/com/nowhere/chooser/UnkeptRestored.java" \
  "$D/src/com/nowhere/chooser/UnkeptRestoredCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.UnkeptRestoredCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
