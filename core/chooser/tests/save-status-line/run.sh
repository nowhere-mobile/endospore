#!/usr/bin/env bash
# run.sh <SaveStatusLine.java> -- NWP-20261104-09: compile the pure status-line decision with its cases and run them.
# $JAVAC / $JAVA default to PATH; test-save-status-line-java.sh is the CI entry point. Its scratch dir is made under
# $TMPDIR, which the wrapper points into its own root.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh SaveStatusLine.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/SaveStatusLine.java"
# The cases live in the default package, so they reach the package-private class through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/SaveStatusLineCases.java" > "$D/com/nowhere/chooser/SaveStatusLineCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D"/com/nowhere/chooser/*.java || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.SaveStatusLineCases || exit 1
