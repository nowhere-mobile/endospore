#!/usr/bin/env bash
# run.sh <EmergencyEditGate.java> -- NWP-20261210-21: compile the pure EmergencyInfo editor rule with its cases and run
# them. $JAVAC / $JAVA default to PATH; core/chooser/test-emergency-edit-gate-java.sh is the CI entry point and exports
# W, its one temp root. Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh EmergencyEditGate.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${W:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/EmergencyEditGate.java"
# The cases live in the default package, so they reach the package-private class through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/EmergencyEditGateCases.java" > "$D/com/nowhere/chooser/EmergencyEditGateCases.java"
"$JAVAC" -J-Djava.io.tmpdir="$D" -d "$D/out" "$D"/com/nowhere/chooser/*.java || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.EmergencyEditGateCases || exit 1
