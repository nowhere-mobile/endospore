#!/usr/bin/env bash
# run.sh <HeldElsewhereCopy.java> -- NWP-20261120-15: compile HeldElsewhereCopy directly (pure Java, no android.*)
# with HeldElsewhereCases and run it. $JAVAC / $JAVA default to PATH; test-held-elsewhere-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 2 = no source file; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/HeldElsewhereCopy.java}"
[ -f "$SRC" ] || { echo "FAIL c0: no HeldElsewhereCopy.java at $SRC"; exit 2; }
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/HeldElsewhereCopy.java"
# The cases live in the default package, so they reach the package-private class through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/HeldElsewhereCases.java" > "$D/com/nowhere/chooser/HeldElsewhereCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/HeldElsewhereCopy.java" \
  "$D/com/nowhere/chooser/HeldElsewhereCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.HeldElsewhereCases || exit 1
