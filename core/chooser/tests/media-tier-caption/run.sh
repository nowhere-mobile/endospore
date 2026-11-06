#!/usr/bin/env bash
# run.sh <MediaTierCopy.java> -- NWP-20261105-10: compile MediaTierCopy directly (pure Java, no android.*) with
# MediaTierCaptionCases and run it. $JAVAC / $JAVA default to PATH; test-export-copy-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/MediaTierCopy.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${TMPDIR:-/tmp}")
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/MediaTierCopy.java"
# The cases live in the default package, so they reach the package-private MediaTierCopy through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/MediaTierCaptionCases.java" > "$D/com/nowhere/chooser/MediaTierCaptionCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/MediaTierCopy.java" \
  "$D/com/nowhere/chooser/MediaTierCaptionCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.MediaTierCaptionCases || exit 1
