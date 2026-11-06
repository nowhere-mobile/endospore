#!/usr/bin/env bash
# run.sh <ResumeReply.java> <workdir> [--kinds tok...] -- NWP-20261109-19: compile the real ResumeReply (pure java.lang,
# so nothing is lifted) with ResumeReplyCases under plain javac/java and run the cases (or, with --kinds, print the
# verdict of each token). The work dir comes from the caller, which owns its cleanup (test-resume-reply-java.sh makes
# ONE root and removes it on exit). The compiler and VM come from $JAVAC / $JAVA.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = the source is missing
# (never a silent skip); 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ResumeReply.java workdir [--kinds tok...]}"
D="${2:?usage: run.sh path/to/ResumeReply.java workdir [--kinds tok...]}"
shift 2
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 2; }
O=$(mktemp -d -p "$D")
cp "$SRC" "$here/ResumeReplyCases.java" "$O/"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$O" "$O/ResumeReply.java" "$O/ResumeReplyCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$O" com.nowhere.chooser.ResumeReplyCases "$@" || rc=$?
rm -rf "$O"
exit "$rc"
