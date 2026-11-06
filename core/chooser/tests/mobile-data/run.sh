#!/usr/bin/env bash
# run.sh <MobileData.java> -- NWP-20261026-07: compile the chooser's pure Mobile data decisions directly and run
# MobileDataCases against them. $JAVAC / $JAVA / $W come from core/chooser/test-mobile-data-java.sh (W is its temp root;
# every temp is made inside it). Exit codes: 1 = a case failed; 3 = it did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/MobileData.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${W:?W is the temp root of the caller}")
grep -v '^package ' "$SRC" > "$D/MobileData.java"
cp "$here/MobileDataCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/MobileData.java" "$D/MobileDataCases.java" || exit 3
rc=0
"$JAVA" -Dfile.encoding=UTF-8 -Djava.io.tmpdir="$W" -cp "$D" MobileDataCases || rc=$?
rm -rf "$D"
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
