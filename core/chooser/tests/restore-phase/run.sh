#!/usr/bin/env bash
# run.sh <RestorePhase.java> <ChooserActivity.java> -- NWP-20261027-11: compile RestorePhase (pure Java) with
# RestorePhaseCases and run them, which also pin onRestoreProgress's wiring in ChooserActivity. JAVAC and JAVA name the
# tools; core/chooser/test-restore-phase-java.sh resolves them and is what CI runs. Exit status: 0 pass; 1 a case or pin
# failed; 2 cannot run (a file missing); 3 the sources did not compile.
set -uo pipefail
RP="${1:?usage: run.sh RestorePhase.java ChooserActivity.java}"; CA="${2:?}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
for f in "$RP" "$CA" "$here/RestorePhaseCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
D=$(mktemp -d) || exit 2
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/src/com/nowhere/chooser"
cp "$RP" "$D/src/com/nowhere/chooser/RestorePhase.java"
cp "$here/RestorePhaseCases.java" "$D/src/com/nowhere/chooser/"
"$JAVAC" -encoding UTF-8 -d "$D/out" "$D"/src/com/nowhere/chooser/*.java || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.RestorePhaseCases "$CA"
