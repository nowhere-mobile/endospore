#!/usr/bin/env bash
# run.sh <OwnedSims.java> <workdir> -- NWP-20261023-12: compile the real OwnedSims (pure java.util, so nothing is lifted)
# and BindFormFields (also pure, taken from the repo source tree, not from SRC's directory: a parse mutant sits alone in a
# temp dir) with OwnedSimsCases under plain javac/java and run the cases. The work dir comes from the caller, which owns its
# cleanup (test-owned-sims-java.sh makes ONE root and removes it on exit). The compiler and VM come from $JAVAC / $JAVA.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = the source is missing
# (never a silent skip); 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/OwnedSims.java workdir}"
D="${2:?usage: run.sh path/to/OwnedSims.java workdir}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 2; }
O=$(mktemp -d -p "$D")
BFF="$here/../../src/com/nowhere/chooser/BindFormFields.java"
[ -f "$BFF" ] || { echo "missing $BFF" >&2; exit 2; }
cp "$SRC" "$BFF" "$here/OwnedSimsCases.java" "$O/"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$O" "$O/OwnedSims.java" "$O/BindFormFields.java" "$O/OwnedSimsCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$O" com.nowhere.chooser.OwnedSimsCases || rc=$?
rm -rf "$O"
exit "$rc"
