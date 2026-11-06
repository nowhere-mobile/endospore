#!/usr/bin/env bash
# run.sh <repo-root> <workdir> -- NWP-20261127-13: compile the chooser's pure InterruptedInstall (java.* only, no
# Android SDK) with InterruptedInstallCases and run them. Everything it creates lives under <workdir>, which the caller
# owns and removes. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-interrupted-install-java.sh resolves them and is what CI runs.
set -euo pipefail
ROOT="${1:?usage: run.sh path/to/repo workdir}"
WORK="${2:?usage: run.sh path/to/repo workdir}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
CH="$ROOT/core/chooser/src/com/nowhere/chooser"
D=$(mktemp -d -p "$WORK")
"$JAVAC" -J-Djava.io.tmpdir="$WORK" -encoding UTF-8 -d "$D" "$CH/InterruptedInstall.java" "$here/InterruptedInstallCases.java"
"$JAVA" -Djava.io.tmpdir="$WORK" -cp "$D" com.nowhere.chooser.InterruptedInstallCases
