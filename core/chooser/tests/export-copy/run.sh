#!/usr/bin/env bash
# run.sh <ExportCopy.java> -- NWP-20261101-02: compile ExportCopy directly (pure Java, no android.*) with
# ExportCopyCases and run it. $JAVAC / $JAVA default to PATH; test-export-copy-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ExportCopy.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/ExportCopy.java"
# The cases live in the default package, so they reach the package-private ExportCopy through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/ExportCopyCases.java" > "$D/com/nowhere/chooser/ExportCopyCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/ExportCopy.java" \
  "$D/com/nowhere/chooser/ExportCopyCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.ExportCopyCases || exit 1
