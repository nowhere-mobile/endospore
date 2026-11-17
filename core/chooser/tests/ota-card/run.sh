#!/usr/bin/env bash
# run.sh <OtaCard.java> <ChooserActivity.java> -- NWP-20261206-19: compile the chooser's OtaCard (pure Java, no Android
# types: it is compiled as it stands) with OtaCardCases and run them under plain javac/java. The cases also pin the
# Install listener, startInstall and renderOtaStatus's Install line in ChooserActivity.java as source. The compiler and
# VM come from $JAVAC / $JAVA (default: PATH); core/vendor-common/bin/test-ota-card-java.sh is the CI entry point.
#
# Exit codes: 1 = a case failed; 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/OtaCard.java path/to/ChooserActivity.java}"
CHO="${2:?usage: run.sh path/to/OtaCard.java path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cp "$SRC" "$D/OtaCard.java"
cp "$here/OtaCardCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -source 8 -target 8 -nowarn -d "$D/out" "$D/OtaCard.java" "$D/OtaCardCases.java" 2>"$D/javac.err" \
  || { cat "$D/javac.err" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.OtaCardCases "$CHO"
