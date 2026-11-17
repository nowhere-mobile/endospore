#!/usr/bin/env bash
# run.sh <DaemonSocket.java> -- NWP-20261022-20, NWP-20261203-06: lift DaemonSocket.connect() and refuse() verbatim by
# signature, and each static member they need verbatim by NAME (MAX_STRANDED, STRANDED, SLOTS, STRANDED_WARNED and the
# four state values), into a harness class DaemonSocket (package com.nowhere.chooser) that declares SOCKET and its own
# CONNECT_CAP_MS = 200 (the real 8000 is pinned by core/vendor-common/bin/test-daemon-connect-java.sh; MAX_STRANDED
# keeps its real value), compile it against the android.net and android.util stubs in stubs/, and run ConnectCases.
# $JAVAC / $JAVA come from the caller.
# Case c7 binds a real AF_UNIX server, so the host must be Linux with a JDK of feature version 16 or later.
#
# Exit codes: 1 = a case failed; 2 = a method or a member did not extract (anchor moved, braces unbalanced, a name
# missing or declared twice), or the host cannot run c7 (not Linux, a JDK older than 16, a socket path too long) --
# never a pass; 3 = the harness or the cases did not compile, or the JVM died with anything but 0/1/2.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/DaemonSocket.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
export PYTHONIOENCODING=utf-8
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${DAEMON_CONNECT_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

CONNECT=$(python3 -I - "$SRC" 'static LocalSocket connect() {' 'private static LocalSocket refuse(int n) {' <<'PY'
import io, sys
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
def fail(msg):
    sys.stderr.write('EXTRACTION FAILED: ' + msg + '\n'); sys.exit(2)
def lift(arg):
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
                return src[line:k + 1]
        k += 1
    fail('unbalanced braces in ' + arg)
print('\n\n'.join(lift(a) for a in sys.argv[2:]))
PY
) || { echo "EXTRACTION FAILED: connect/refuse" >&2; exit 2; }
[ -n "$CONNECT" ] || { echo "EXTRACTION FAILED: empty connect" >&2; exit 2; }

MEMBERS=$(python3 -I - "$SRC" MAX_STRANDED STRANDED SLOTS STRANDED_WARNED PENDING CONNECTED FAILED ABANDONED <<'PY'
import io, re, sys
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
for name in sys.argv[2:]:
    pat = re.compile(r'^[ \t]*(?:private[ \t]+)?static[ \t]+final[ \t]+\S+[ \t]+' + name + r'[ \t]*=.*;[ \t]*(?://.*)?$', re.M)
    got = pat.findall(src)
    if len(got) != 1:
        sys.stderr.write('EXTRACTION FAILED: %d declarations of %s\n' % (len(got), name)); sys.exit(2)
    print(got[0])
PY
) || { echo "EXTRACTION FAILED: members" >&2; exit 2; }

[ "$(uname -s)" = Linux ] || { echo "UNSUPPORTED: case c7 needs Linux AF_UNIX sockets (uname -s: $(uname -s))" >&2; exit 2; }
jv=$("$JAVA" -XshowSettings:properties -version 2>&1 | sed -n 's/^[[:space:]]*java\.specification\.version = //p')
case "$jv" in
  ''|*[!0-9]*) echo "UNSUPPORTED: cannot read the JDK feature version (got '${jv}'); case c7 needs Java 16+" >&2; exit 2 ;;
esac
[ "$jv" -ge 16 ] || { echo "UNSUPPORTED: the JDK is version $jv; case c7 needs Java 16+ (UnixDomainSocketAddress)" >&2; exit 2; }

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
{
  echo 'package com.nowhere.chooser;'
  echo 'import android.net.LocalSocket;'
  echo 'import android.net.LocalSocketAddress;'
  echo 'import java.util.concurrent.CountDownLatch;'
  echo 'import java.util.concurrent.Semaphore;'
  echo 'import java.util.concurrent.TimeUnit;'
  echo 'import java.util.concurrent.atomic.AtomicBoolean;'
  echo 'import java.util.concurrent.atomic.AtomicInteger;'
  echo 'final class DaemonSocket {'
  echo '    static final String SOCKET = "nowhere_login";'
  echo '    static final int CONNECT_CAP_MS = 200; // the harness cap; the shipped 8000 is pinned by the suite'
  printf '%s\n' "$MEMBERS"
  printf '%s\n' "$CONNECT"
  echo '}'
} > "$D/src/com/nowhere/chooser/DaemonSocket.java"

"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" $(find "$here/stubs" -name '*.java') \
    "$D/src/com/nowhere/chooser/DaemonSocket.java" "$here/ConnectCases.java" 2>"$D/javac.err" \
  || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.ConnectCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || [ "$rc" = 2 ] || exit 3
exit "$rc"
