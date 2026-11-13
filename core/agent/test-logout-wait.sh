#!/usr/bin/env bash
# test-logout-wait.sh [--mutate] -- runs the LOGOUT wait cases (logout_wait_test.go; NWP-20261106-04, Q116);
# --mutate re-runs them against main.go / logout_wait.go broken in turn, restoring both on exit. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
# Since NWP-20261129-51 W1, W2 and W5 step lockSessionForLogout's ticker and clock by hand (logoutWaitTicker,
# logoutWaitNow) and read a recording conn, so no load can fail them; M1 waits out W5's 30 s hang guard to convict.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'for f in main.go logout_wait.go; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'LogoutWait' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp logout_wait.go "$W/logout_wait.go.orig"
fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 f=$2 res
  python3 - "$f" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$f.orig" "$f"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$f.orig" "$f"
}
BLK='\t\tif name == "LOGOUT" {\n\t\t\tlockSessionForLogout(conn, dest)\n\t\t} else {\n\t\t\tsessionMu.Lock()\n\t\t}\n'
TICK='\t\tcase <-tc:\n\t\t\tconn.SetDeadline(time.Now().Add(loginConnDeadline))\n'
mut "M1 LOGOUT back to the blocking sessionMu.Lock()" main.go \
  "s.replace('\t\t\tlockSessionForLogout(conn, dest)\n', '\t\t\tsessionMu.Lock()\n', 1) if s.count('\t\t\tlockSessionForLogout(conn, dest)\n') == 1 else None"
mut "M2 WAIT written before logoutWaitFirst" logout_wait.go \
  "s.replace('case <-tc:\n\t\t\tconn.SetDeadline(time.Now().Add(loginConnDeadline))\n\t\t\tif waited := logoutWaitNow().Sub(start); waited >= logoutWaitFirst {', 'case <-tc:\n\t\t\tconn.SetDeadline(time.Now().Add(loginConnDeadline))\n\t\t\tif waited := logoutWaitNow().Sub(start); waited >= 0 {', 1) if s.count('case <-tc:') == 1 else None"
mut "M3 every serialized verb goes through lockSessionForLogout" main.go \
  "s.replace('$BLK', '\t\tlockSessionForLogout(conn, dest)\n', 1) if s.count('$BLK') == 1 else None"
mut "M4 WAIT without the seconds" logout_wait.go \
  "s.replace('\"WAIT %d\\\\n\", int(waited/time.Second))', '\"WAIT\\\\n\")', 1) if s.count('\"WAIT %d\\\\n\", int(waited/time.Second))') == 1 else None"
mut "M5 the per-tick deadline re-arm removed" logout_wait.go \
  "s.replace('$TICK', '\t\tcase <-tc:\n', 1) if s.count('$TICK') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
