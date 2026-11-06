#!/usr/bin/env bash
# run.sh <DataRoaming.java> -- NWP-20261028-06: compile DataRoaming directly (pure Java, no android.*) with
# DataRoamingCases and run it. $JAVAC / $JAVA default to PATH; test-data-roaming-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/DataRoaming.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/DataRoaming.java"
# The cases live in the default package, so they reach the package-private DataRoaming through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/DataRoamingCases.java" > "$D/com/nowhere/chooser/DataRoamingCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" \
  "$D/com/nowhere/chooser/DataRoaming.java" "$D/com/nowhere/chooser/DataRoamingCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.DataRoamingCases || exit 1
