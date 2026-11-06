#!/usr/bin/env bash
# run.sh <StoreService.java> -- NWP-20261103-14: lift the index-refresh-gate fence (indexRefreshAllowed) out of the
# chooser's StoreService and run Cases against it under plain javac/java. The fence uses only java.lang. The compiler
# and VM come from $JAVAC / $JAVA (default: PATH); core/vendor-common/bin/test-index-refresh-gate-java.sh is the CI
# entry point. $NWP_WORK, when set, is the caller's temp root (so everything lives under its one trap).
#
# Exit codes: 1 = a case failed; 2 = the fence or its method is missing (never a silent skip); 3 = a compile error.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/StoreService.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${NWP_WORK:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT
{
  echo "final class Lifted {"
  sed -n '/BEGIN index-refresh-gate/,/END index-refresh-gate/p' "$SRC"
  echo "}"
} > "$D/Lifted.java"
grep -q 'static boolean indexRefreshAllowed(' "$D/Lifted.java" || { echo "extraction missed indexRefreshAllowed" >&2; exit 2; }
cp "$here/Cases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/Cases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" Cases
