#!/usr/bin/env bash
# run.sh <repo-root> <workdir> -- NWP-20261020-22: compile the chooser's pure NfcShuttle and NfcTapVerdict
# (NWP-20261109-05; java.* only, no Android SDK) with NfcShuttleCases and run them. Everything it creates lives under
# <workdir>, which the caller owns and removes. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-nfc-shuttle-java.sh resolves them and is what CI runs.
set -euo pipefail
ROOT="${1:?usage: run.sh path/to/repo workdir}"
WORK="${2:?usage: run.sh path/to/repo workdir}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
CH="$ROOT/core/chooser/src/com/nowhere/chooser"
D=$(mktemp -d -p "$WORK")
"$JAVAC" -J-Djava.io.tmpdir="$WORK" -encoding UTF-8 -d "$D" "$CH/NfcShuttle.java" "$CH/NfcTapVerdict.java" "$here/NfcShuttleCases.java"
"$JAVA" -Djava.io.tmpdir="$WORK" -cp "$D" com.nowhere.chooser.NfcShuttleCases
