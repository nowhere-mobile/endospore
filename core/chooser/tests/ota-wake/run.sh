#!/usr/bin/env bash
# run.sh <OtaWakeReceiver.java> -- NWP-20261022-13: compile the REAL OtaWakeReceiver (unchanged) against the android.* and
# DaemonSocket stubs in stubs/ and run OtaWakeCases. $JAVAC / $JAVA come from core/chooser/test-ota-wake-java.sh.
# Exit codes: 1 = a case failed; 3 = the sources did not compile, or the JVM died with anything but 0/1.
set -euo pipefail
SRC="${1:?usage: run.sh OtaWakeReceiver.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${OTA_WAKE_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$SRC" "$D/src/com/nowhere/chooser/OtaWakeReceiver.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" $(find "$here/stubs" -name '*.java') \
    "$D/src/com/nowhere/chooser/OtaWakeReceiver.java" "$here/OtaWakeCases.java" 2>"$D/javac.err" \
  || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.OtaWakeCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
