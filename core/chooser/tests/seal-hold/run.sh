#!/usr/bin/env bash
# run.sh <repo-root> -- NWP-20261011-01: compile the chooser's pure SealHold (java.lang only, no Android SDK) with
# SealHoldCases and run them. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-seal-hold-java.sh resolves them and is what CI runs.
set -euo pipefail
ROOT="${1:?usage: run.sh path/to/repo}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
"$JAVAC" -encoding UTF-8 -d "$D" "$ROOT/core/chooser/src/com/nowhere/chooser/SealHold.java" "$here/SealHoldCases.java"
"$JAVA" -cp "$D" com.nowhere.chooser.SealHoldCases \
  "$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java" \
  "$ROOT/core/vendor-common/bin/nowhere_roamd.sh" \
  "$ROOT/core/agent/seal_hold.go"
