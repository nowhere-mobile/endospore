#!/usr/bin/env bash
# run.sh <ReloginCopy.java> <ChooserActivity.java> <ReloginReceiver.java> -- NWP-20261103-09 (Q068): compile the
# verbatim ReloginCopy with Cases and run it, and pin the wiring the class cannot see: postReconnectNotice posts
# ReloginCopy.RECONNECT_BODY, ReloginReceiver's read cap covers the daemon's store check and it classifies the reply
# through ReloginCopy.verdict. $JAVAC / $JAVA come from the caller (core/vendor-common/bin/test-relogin-copy-java.sh).
#
# Exit codes: 1 = a case or pin failed; 2 = a file or method did not extract; 3 = the cases did not compile.
set -euo pipefail
COPY="${1:?usage: run.sh ReloginCopy.java ChooserActivity.java ReloginReceiver.java}"
CHOOSER="${2:?}"
RECV="${3:?}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)  # the suite calls this with TMPDIR inside its own root
trap 'rm -rf "$D"' EXIT
for f in "$COPY" "$CHOOSER" "$RECV"; do
  [ -f "$f" ] || { echo "EXTRACTION FAILED: $f is missing" >&2; exit 2; }
done
imp=$(grep -c 'import android' "$COPY" || true)
[ "$imp" = 0 ] || { echo "EXTRACTION FAILED: ReloginCopy imports android" >&2; exit 2; }
blk=$(awk '
  !on && index($0, "private static void postReconnectNotice(") { on=1; depth=0 }
  on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
' "$CHOOSER")
[ -n "$blk" ] || { echo "EXTRACTION FAILED: postReconnectNotice is missing" >&2; exit 2; }

fail=0
pin() { # pin <label> <ok: 1|0>
  if [ "$2" = 1 ]; then echo "  ok    pin: $1"; else echo "  FAIL  pin: $1"; fail=1; fi
}
cnt() { grep -cF -- "$2" <<<"$1" || true; }
pin "postReconnectNotice posts ReloginCopy.RECONNECT_BODY once" \
    "$([ "$(cnt "$blk" 'String body = ReloginCopy.RECONNECT_BODY;')" = 1 ] && echo 1 || echo 0)"
pin "postReconnectNotice has no inline discard sentence" \
    "$([ "$(cnt "$blk" 'will be discarded')" = 0 ] && echo 1 || echo 0)"
rsrc=$(cat "$RECV")
pin "READ_CAP_MS is 30000" \
    "$([ "$(grep -cE '^    private static final int READ_CAP_MS = 30000;' <<<"$rsrc" || true)" = 1 ] && echo 1 || echo 0)"
pin "CONNECT_CAP_MS is 40000" \
    "$([ "$(grep -cE '^    private static final int CONNECT_CAP_MS = 40000;' <<<"$rsrc" || true)" = 1 ] && echo 1 || echo 0)"
pin "ReloginReceiver classifies the reply through ReloginCopy.verdict" \
    "$([ "$(cnt "$rsrc" 'ReloginCopy.verdict(')" -ge 1 ] && echo 1 || echo 0)"

mkdir -p "$D/src/com/nowhere/chooser"
cp "$COPY" "$D/src/com/nowhere/chooser/ReloginCopy.java"
cp "$here/Cases.java" "$D/src/com/nowhere/chooser/Cases.java"
"$JAVAC" -encoding UTF-8 -d "$D/out" "$D/src/com/nowhere/chooser/ReloginCopy.java" \
    "$D/src/com/nowhere/chooser/Cases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.Cases || rc=1
[ "$fail" = 0 ] && [ "$rc" = 0 ] || exit 1
