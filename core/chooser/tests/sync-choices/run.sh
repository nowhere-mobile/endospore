#!/usr/bin/env bash
# run.sh <SyncChoices.java> <ReplyCopy.java> -- NWP-20261202-25: compile SyncChoices (pure Java, no android.*) with
# ReplyCopy and SyncChoicesCases, and run the cases. $JAVAC / $JAVA default to PATH; test-sync-choices-java.sh is the
# CI entry point and finds them.
# Exit codes: 1 = a case failed; 3 = the sources or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/SyncChoices.java path/to/ReplyCopy.java}"
RCS="${2:?usage: run.sh path/to/SyncChoices.java path/to/ReplyCopy.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/SyncChoices.java"
cp "$RCS" "$D/com/nowhere/chooser/ReplyCopy.java"
# The cases live in the default package, so they reach the package-private classes through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/SyncChoicesCases.java" > "$D/com/nowhere/chooser/SyncChoicesCases.java"
"$JAVAC" -d "$D/out" "$D/com/nowhere/chooser/SyncChoices.java" "$D/com/nowhere/chooser/ReplyCopy.java" \
  "$D/com/nowhere/chooser/SyncChoicesCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.SyncChoicesCases || exit 1
