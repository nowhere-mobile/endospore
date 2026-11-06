#!/usr/bin/env bash
# run.sh <ReplyCopy.java> -- NWP-20261020-11: compile ReplyCopy directly (pure Java, no android.*) with ReplyCopyCases
# and run it. $JAVAC / $JAVA default to PATH; test-reply-copy-java.sh is the CI entry point and finds them.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ReplyCopy.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/ReplyCopy.java"
cp "$here/ReplyCopyCases.java" "$D/"
# The cases live in the default package, so they reach the package-private ReplyCopy through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$D/ReplyCopyCases.java" > "$D/com/nowhere/chooser/ReplyCopyCases.java"
rm "$D/ReplyCopyCases.java"
"$JAVAC" -d "$D/out" "$D/com/nowhere/chooser/ReplyCopy.java" "$D/com/nowhere/chooser/ReplyCopyCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.ReplyCopyCases || exit 1
