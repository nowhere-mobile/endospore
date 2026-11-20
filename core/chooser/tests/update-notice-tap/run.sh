#!/usr/bin/env bash
# run.sh <UpdateNoticeTap.java> -- NWP-20261208-32: compile the REAL UpdateNoticeTap and the REAL LandingLine (both
# unchanged) against the android.* stubs in stubs/ and run UpdateNoticeTapCases. $JAVAC / $JAVA come from
# core/chooser/test-update-notice-tap-java.sh.
# Exit codes: 1 = a case failed; 3 = the source is missing, did not compile, or the JVM died with anything but 0/1.
set -euo pipefail
SRC="${1:?usage: run.sh UpdateNoticeTap.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
LANDING="$here/../../src/com/nowhere/chooser/LandingLine.java"
[ -f "$SRC" ] || { echo "run.sh: no $SRC" >&2; exit 3; }
[ -f "$LANDING" ] || { echo "run.sh: no $LANDING" >&2; exit 3; }
D=$(mktemp -d -p "${UPDATE_NOTICE_TAP_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$SRC" "$D/src/com/nowhere/chooser/UpdateNoticeTap.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" $(find "$here/stubs" -name '*.java') \
    "$D/src/com/nowhere/chooser/UpdateNoticeTap.java" "$LANDING" "$here/UpdateNoticeTapCases.java" 2>"$D/javac.err" \
  || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.UpdateNoticeTapCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
