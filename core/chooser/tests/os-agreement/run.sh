#!/usr/bin/env bash
# run.sh <OsAgreement.java> -- NWP-20261114-11: compile the OS agreement class as-is with OsAgreementCases and run the
# cases under plain javac/java. The class is pure java.lang, so nothing is lifted. $JAVAC / $JAVA come from the caller
# (core/vendor-common/bin/test-os-agreement-java.sh), which sets TMPDIR inside its own root.
#
# Exit codes: 1 = a case failed; 2 = a source is missing; 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/OsAgreement.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$SRC" ] || { echo "  FAIL missing $SRC" >&2; exit 2; }
[ -f "$here/OsAgreementCases.java" ] || { echo "  FAIL missing $here/OsAgreementCases.java" >&2; exit 2; }
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cp "$SRC" "$D/OsAgreement.java"
cp "$here/OsAgreementCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D" "$D/OsAgreement.java" "$D/OsAgreementCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" com.nowhere.chooser.OsAgreementCases || exit 1
