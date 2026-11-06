#!/usr/bin/env bash
# run.sh <core/chooser dir> [<core/agent dir>] -- NWP-20261128-12: compile OwnerInboxReply (pure, java.lang / java.util
# only) with OwnerInboxReplyCases and run the cases: the reply rules, the wiring in
# ChooserActivity.buildOwnerInboxScreen, and the daemon's reply in core/agent/telephony_owner.go. The agent dir
# defaults to <core/chooser dir>/../agent. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-owner-inbox-reply-java.sh resolves them and is what CI runs. Exit status: 0 every case
# passed; 1 a case failed; 2 cannot run (a tool or a file missing); 3 the class does not compile. --mutate counts only
# a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir> [<core/agent dir>]}"
AG="${2:-$CH/../agent}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
OR="$J/OwnerInboxReply.java"; CA="$J/ChooserActivity.java"; GO="$AG/telephony_owner.go"
for f in "$OR" "$CA" "$GO" "$here/OwnerInboxReplyCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
D=$(mktemp -d) || exit 2
trap 'rm -rf "$D"' EXIT
"$JAVAC" -encoding UTF-8 -d "$D" "$OR" "$here/OwnerInboxReplyCases.java" \
  || { echo "run.sh: OwnerInboxReply does not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" com.nowhere.chooser.OwnerInboxReplyCases "$CA" "$GO"
