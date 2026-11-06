#!/usr/bin/env bash
# run.sh <PendingRow.java> -- NWP-20261027-12: compile the chooser's PendingRow (pure Java, no Android types: compiled as
# it stands) with PendingRowCases and run them. The compiler and VM come from $JAVAC / $JAVA (default: PATH);
# core/chooser/test-pending-row-java.sh is the CI entry point and finds them. Every temp lives inside one root.
#
# Exit codes: 1 = a case failed; 2 = no temp dir; 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/PendingRow.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d) || exit 2
trap 'rm -rf "$D"' EXIT
cp "$SRC" "$D/PendingRow.java"
cp "$here/PendingRowCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -source 8 -target 8 -nowarn -d "$D/out" "$D/PendingRow.java" "$D/PendingRowCases.java" 2>"$D/javac.err" \
  || { cat "$D/javac.err" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.PendingRowCases
