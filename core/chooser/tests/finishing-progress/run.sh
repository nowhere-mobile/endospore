#!/usr/bin/env bash
# run.sh <FinishingProgress.java> <ChooserActivity.java> -- NWP-20261208-25: compile FinishingProgress (pure Java) with
# FinishingProgressCases and run them, which also pin the finish block's wiring in ChooserActivity. JAVAC and JAVA name
# the tools; core/chooser/test-finishing-progress-java.sh resolves them and is what CI runs. Exit status: 0 pass; 1 a
# case or pin failed; 2 cannot run (a file missing); 3 the sources did not compile.
set -uo pipefail
FP="${1:?usage: run.sh FinishingProgress.java ChooserActivity.java}"; CA="${2:?}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
for f in "$FP" "$CA" "$here/FinishingProgressCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
D=$(mktemp -d) || exit 2
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/src/com/nowhere/chooser"
cp "$FP" "$D/src/com/nowhere/chooser/FinishingProgress.java"
cp "$here/FinishingProgressCases.java" "$D/src/com/nowhere/chooser/"
"$JAVAC" -J-Djava.io.tmpdir="$D" -encoding UTF-8 -d "$D/out" "$D"/src/com/nowhere/chooser/*.java || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.FinishingProgressCases "$CA"
