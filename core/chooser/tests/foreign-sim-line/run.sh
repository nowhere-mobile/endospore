#!/usr/bin/env bash
# run.sh <ForeignSimLine.java> <workdir> -- NWP-20261122-13: compile the real ForeignSimLine (pure java.util, so nothing
# is lifted) with OwnedSims and BindFormFields (also pure, taken from the repo source tree, not from SRC's directory: a
# mutant sits alone in a temp dir) and ForeignSimLineCases under plain javac/java, and run the cases. The work dir comes
# from the caller, which owns its cleanup (test-foreign-sim-line-java.sh makes ONE root and removes it on exit). The
# compiler and VM come from $JAVAC / $JAVA.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = a source is missing
# (never a silent skip); 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ForeignSimLine.java workdir}"
D="${2:?usage: run.sh path/to/ForeignSimLine.java workdir}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 2; }
SRCDIR="$here/../../src/com/nowhere/chooser"
for f in "$SRCDIR/OwnedSims.java" "$SRCDIR/BindFormFields.java"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 2; }; done
O=$(mktemp -d -p "$D")
cp "$SRC" "$SRCDIR/OwnedSims.java" "$SRCDIR/BindFormFields.java" "$here/ForeignSimLineCases.java" "$O/"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$O" "$O/ForeignSimLine.java" "$O/OwnedSims.java" \
  "$O/BindFormFields.java" "$O/ForeignSimLineCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$O" com.nowhere.chooser.ForeignSimLineCases || rc=$?
rm -rf "$O"
exit "$rc"
