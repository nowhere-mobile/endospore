#!/usr/bin/env bash
# test-create-live.sh [--mutate] -- runs the live-session create cases (create_live_test.go; NWP-20261101-04, Q087):
# CREATE and CREATE-CODE answer ERR-LIVE while .roamsession stands, before the store, the gateway or the throttle.
# --mutate re-runs them against main.go with the guard broken in turn, restoring the file on exit. Each mutant must
# be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=main.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'CreateLive' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
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
  cp -f "$W/$F.orig" "$F"
}
CREATE='refuseCreateOverColdLock(conn, dest) || refuseCreateOverLiveSession(conn, dest) || !createPrecheck'
CODE='\tif refuseCreateOverLiveSession(conn, dest) { // NWP-20261101-04: likewise, a refused create redeems nothing\n\t\treturn\n\t}\n'
mut "L1 the handleCreate call removed" \
  "s.replace('$CREATE', 'refuseCreateOverColdLock(conn, dest) || !createPrecheck', 1) if s.count('$CREATE') == 1 else None"
mut "L2 the handleCreateCode call moved after the drain" \
  "s.replace('$CODE', '', 1).replace('\tn, err := drainClaim(newGatewayClient(gw, gwDefault), staged, code, false)', '\tn, err := drainClaim(newGatewayClient(gw, gwDefault), staged, code, false)\n$CODE', 1) if s.count('$CODE') == 1 and s.count('\tn, err := drainClaim(newGatewayClient(gw, gwDefault), staged, code, false)') == 1 else None"
mut "L3 refuseCreateOverLiveSession always false" \
  "s.replace('\tif !roamSessionExists(dest) {\n\t\treturn false\n\t}\n\tfmt.Fprint(os.Stderr, \"[logind] create refused: a roamed', '\treturn false\n\tfmt.Fprint(os.Stderr, \"[logind] create refused: a roamed', 1)"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
