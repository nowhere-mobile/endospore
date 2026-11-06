#!/usr/bin/env bash
# run.sh <PinCopy.java> -- NWP-20261124-10: compile PinCopy directly (pure Java, no android.*) with PinCopyCases and
# run it. $JAVAC / $JAVA default to PATH; test-pin-copy-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/PinCopy.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
[ -f "$SRC" ] || { echo "FAIL: no $SRC"; exit 3; }
cp "$SRC" "$D/com/nowhere/chooser/PinCopy.java"
# The cases live in the default package, so they reach the package-private PinCopy through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/PinCopyCases.java" > "$D/com/nowhere/chooser/PinCopyCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/PinCopy.java" \
  "$D/com/nowhere/chooser/PinCopyCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.PinCopyCases || exit 1
