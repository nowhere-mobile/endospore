#!/usr/bin/env bash
# run.sh <SnapshotCopy.java> -- NWP-20261027-07: compile SnapshotCopy directly (pure Java, no android.*) with
# SnapshotCopyCases and run it. $JAVAC / $JAVA default to PATH; test-snapshot-copy-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/SnapshotCopy.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/SnapshotCopy.java"
# The cases live in the default package, so they reach the package-private SnapshotCopy through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/SnapshotCopyCases.java" > "$D/com/nowhere/chooser/SnapshotCopyCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/SnapshotCopy.java" \
  "$D/com/nowhere/chooser/SnapshotCopyCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.SnapshotCopyCases || exit 1
