#!/usr/bin/env bash
# run.sh <repo-root> -- NWP-20261019-04: compile the chooser's pure TelKick (java.lang only, no Android SDK) with
# TelKickCases and run them. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-tel-kick-java.sh resolves them and is what CI runs.
set -euo pipefail
ROOT="${1:?usage: run.sh path/to/repo}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
"$JAVAC" -encoding UTF-8 -d "$D" "$ROOT/core/chooser/src/com/nowhere/chooser/TelKick.java" "$here/TelKickCases.java"
"$JAVA" -cp "$D" com.nowhere.chooser.TelKickCases \
  "$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
