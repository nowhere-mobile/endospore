#!/usr/bin/env bash
# run.sh <core/chooser dir> <core/agent/main.go> -- NWP-20261120-14: compile WifiMirrorPick.java ALONE (no Android types)
# and run Cases against it, WifiMirror.java (capture, by text) and main.go (handleWifiMirror's bound). JAVAC and JAVA name
# the tools (default: on PATH); core/chooser/test-wifi-mirror-pick-java.sh resolves them and is what CI runs. WMP_TMP names
# the work dir (the driver makes it inside its own root); without it run.sh makes its own. Exit status: 0 every case
# passed; 1 a case failed; 2 cannot run (a tool, file or anchor missing); 3 WifiMirrorPick.java does not compile.
# --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir> <main.go>}"
GO="${2:?usage: run.sh <core/chooser dir> <main.go>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
for f in "$J/WifiMirrorPick.java" "$J/WifiMirror.java" "$GO" "$here/Cases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
if [ -n "${WMP_TMP:-}" ]; then
  D=$WMP_TMP
else
  D=$(mktemp -d) || exit 2
  trap 'rm -rf "$D"' EXIT
fi
cp "$J/WifiMirrorPick.java" "$here/Cases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/WifiMirrorPick.java" "$D/Cases.java" || { echo "run.sh: WifiMirrorPick.java does not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" com.nowhere.chooser.Cases "$J/WifiMirror.java" "$GO"
