#!/usr/bin/env bash
# run.sh <DaemonSocket.java> -- NWP-20261022-20: lift DaemonSocket.connect() verbatim by signature into a harness class
# DaemonSocket (package com.nowhere.chooser) that declares SOCKET and its own CONNECT_CAP_MS = 200 (the real 8000 is
# pinned by core/vendor-common/bin/test-daemon-connect-java.sh), compile it against the android.net stubs in stubs/, and
# run ConnectCases. $JAVAC / $JAVA come from the caller.
#
# Exit codes: 1 = a case failed; 2 = connect() did not extract (anchor moved or braces unbalanced); 3 = the harness or
# the cases did not compile, or the JVM died with anything but 0/1.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/DaemonSocket.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
export PYTHONIOENCODING=utf-8
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${DAEMON_CONNECT_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

CONNECT=$(python3 -I - "$SRC" 'static LocalSocket connect() {' <<'PY'
import io, sys
path, arg = sys.argv[1:3]
src = io.open(path, encoding='utf-8').read()
def fail(msg):
    sys.stderr.write('EXTRACTION FAILED: ' + msg + '\n'); sys.exit(2)
if src.count(arg) != 1:
    fail('%d matches of %s' % (src.count(arg), arg))
i = src.index(arg)
line = src.rfind('\n', 0, i) + 1          # whole first line, indentation included
k = src.index('{', i); depth = 0; end = len(src)
while k < end:
    c = src[k]
    if c == '"':
        k += 1
        while k < end and src[k] != '"':
            k += 2 if src[k] == '\\' else 1
    elif c == "'":
        k += 1
        while k < end and src[k] != "'":
            k += 2 if src[k] == '\\' else 1
    elif src.startswith('//', k):
        k = src.find('\n', k)
        if k < 0: break
    elif src.startswith('/*', k):
        k = src.find('*/', k + 2)
        if k < 0: break
        k += 1
    elif c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            print(src[line:k + 1]); sys.exit(0)
    k += 1
fail('unbalanced braces in ' + arg)
PY
) || { echo "EXTRACTION FAILED: connect" >&2; exit 2; }
[ -n "$CONNECT" ] || { echo "EXTRACTION FAILED: empty connect" >&2; exit 2; }

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
{
  echo 'package com.nowhere.chooser;'
  echo 'import android.net.LocalSocket;'
  echo 'import android.net.LocalSocketAddress;'
  echo 'import java.util.concurrent.atomic.AtomicBoolean;'
  echo 'final class DaemonSocket {'
  echo '    static final String SOCKET = "nowhere_login";'
  echo '    static final int CONNECT_CAP_MS = 200; // the harness cap; the shipped 8000 is pinned by the suite'
  printf '%s\n' "$CONNECT"
  echo '}'
} > "$D/src/com/nowhere/chooser/DaemonSocket.java"

"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" $(find "$here/stubs" -name '*.java') \
    "$D/src/com/nowhere/chooser/DaemonSocket.java" "$here/ConnectCases.java" 2>"$D/javac.err" \
  || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.ConnectCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
