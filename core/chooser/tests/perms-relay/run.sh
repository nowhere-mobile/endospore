#!/usr/bin/env bash
# run.sh <PermsRelayGate.java> -- NWP-20261112-10: compile PermsRelayGate directly (pure java.lang) with Cases and run
# them. $JAVAC / $JAVA default to PATH; core/vendor-common/bin/test-perms-relay-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/PermsRelayGate.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/PermsRelayGate.java"
# The cases live in the default package, so they reach the package-private PermsRelayGate through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/Cases.java" > "$D/com/nowhere/chooser/Cases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/PermsRelayGate.java" \
  "$D/com/nowhere/chooser/Cases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.Cases || exit 1
