#!/usr/bin/env bash
# run.sh <IcsExport.java> <workdir> -- NWP-20261109-03: compile the real IcsExport (pure java.*, so nothing is lifted)
# with IcsExportCases under plain javac/java and run the cases. The work dir comes from the caller, which owns its
# cleanup (test-ics-export-java.sh makes ONE root and removes it on exit). The compiler and VM come from $JAVAC / $JAVA.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = the source is missing
# (never a silent skip); 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/IcsExport.java workdir}"
D="${2:?usage: run.sh path/to/IcsExport.java workdir}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 2; }
O=$(mktemp -d -p "$D")
cp "$SRC" "$here/IcsExportCases.java" "$O/"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$O" "$O/IcsExport.java" "$O/IcsExportCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$O" com.nowhere.chooser.IcsExportCases || rc=$?
rm -rf "$O"
exit "$rc"
