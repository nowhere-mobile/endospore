#!/usr/bin/env bash
# run.sh <core/chooser dir> -- NWP-20261015-31: compile WifiMirrorLine.java ALONE (no Android types) and run Cases against
# it, plus the two call sites that must go through it. JAVAC and JAVA name the tools (default: on PATH);
# core/vendor-common/bin/test-wifi-mirror-java.sh resolves them and is what CI runs. Exit status: 0 every case passed;
# 1 a case failed; 2 cannot run (a tool or file missing); 3 WifiMirrorLine.java does not compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
for f in "$J/WifiMirrorLine.java" "$J/WifiMirror.java" "$J/ChooserActivity.java" "$J/DaemonSocket.java" "$here/Cases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cp "$J/WifiMirrorLine.java" "$here/Cases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/WifiMirrorLine.java" "$D/Cases.java" || { echo "run.sh: WifiMirrorLine.java does not compile" >&2; exit 3; }
"$JAVA" -cp "$D" com.nowhere.chooser.Cases "$J/WifiMirror.java" "$J/ChooserActivity.java" "$J/DaemonSocket.java"
