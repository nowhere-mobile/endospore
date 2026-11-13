#!/usr/bin/env bash
# run.sh <repo-root> -- NWP-20261201-05: compile the chooser's pure SaveMode (java.lang only, no Android SDK) with
# SaveModeCases and run them. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-save-mode-java.sh resolves them and is what CI runs.
set -euo pipefail
ROOT="${1:?usage: run.sh path/to/repo}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
"$JAVAC" -J-Djava.io.tmpdir="$D" -encoding UTF-8 -d "$D" "$ROOT/core/chooser/src/com/nowhere/chooser/SaveMode.java" "$here/SaveModeCases.java"
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" com.nowhere.chooser.SaveModeCases \
  "$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java" \
  "$ROOT/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
