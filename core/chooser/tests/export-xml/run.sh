#!/usr/bin/env bash
# run.sh <ExportXml.java> <workdir> -- NWP-20261109-25: compile the real ExportXml (pure java.lang) with ExportXmlCases
# under plain javac/java and run the cases. The work dir comes from the caller, which owns its cleanup. The compiler
# and VM come from $JAVAC / $JAVA.
#
# Exit codes: 1 = a case failed; 2 = the source is missing; 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ExportXml.java workdir}"
D="${2:?usage: run.sh path/to/ExportXml.java workdir}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 2; }
O=$(mktemp -d -p "$D")
cp "$SRC" "$here/ExportXmlCases.java" "$O/"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$O" "$O/ExportXml.java" "$O/ExportXmlCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$O" com.nowhere.chooser.ExportXmlCases || rc=$?
rm -rf "$O"
exit "$rc"
