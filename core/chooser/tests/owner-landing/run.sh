#!/usr/bin/env bash
# run.sh <core/chooser dir> -- NWP-20261129-12: compile OwnerLanding (pure, java.lang only) with OwnerLandingCases and
# run the cases: the rule, and its eight sites read from ChooserActivity's source. JAVAC and JAVA name the tools
# (default: javac, java on PATH); core/vendor-common/bin/test-owner-landing-java.sh resolves them and is what CI runs.
# Exit status: 0 every case passed; 1 a case failed; 2 cannot run (a tool or a file missing); 3 the class does not
# compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
OL="$J/OwnerLanding.java"; CA="$J/ChooserActivity.java"
for f in "$OL" "$CA" "$here/OwnerLandingCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$W" "$OL" "$here/OwnerLandingCases.java" \
  || { echo "run.sh: OwnerLanding does not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$W" com.nowhere.chooser.OwnerLandingCases "$CA"
