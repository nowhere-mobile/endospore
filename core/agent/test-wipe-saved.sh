#!/usr/bin/env bash
# test-wipe-saved.sh [--mutate] -- runs the EVICT-RECHECK-SAVED cases (coldlock_wipe_saved_test.go, the gate-only and
# concurrent-safe pins; NWP-20261106-12); --mutate re-runs them against coldlock_evict.go, owner_key.go and main.go
# with the verb broken in turn, restoring the files on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(coldlock_evict.go owner_key.go main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'EvictRecheckSaved|SavedWipe|TestGateOnly|TestConcurrentSafeCmd' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
# mut <label> <file> <python expression over s (the file) and body (the handler's text)>: exactly one application.
mut() {
  local label=$1 res
  python3 - "$2" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
m = re.search(r'func handleEvictRecheckSaved\(.*?\n}\n', s, re.S)
body = m.group(0) if m else ''
def inh(old, new):
    if body.count(old) != 1: return None
    return s.replace(body, body.replace(old, new, 1), 1)
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  restore
}
mut "E1 WIPE when not saved" coldlock_evict.go \
  "s.replace('\tif saved {\n\t\treturn \"WIPE \" + uid', '\tif true {\n\t\treturn \"WIPE \" + uid', 1) if s.count('\tif saved {\n\t\treturn \"WIPE \" + uid') == 1 else None"
mut "E2 the marker check removed" coldlock_evict.go \
  "inh('cl != uid {', 'cl != uid && false {')"
mut "E3 the live-session check removed" coldlock_evict.go \
  "inh('name != \"\" {', 'name != \"\" && false {')"
mut "E4 the verb not gate-only" owner_key.go \
  "s.replace('\"SEED-SSAID\", \"EVICT-RECHECK-SAVED\":', '\"SEED-SSAID\":', 1) if s.count('\"SEED-SSAID\", \"EVICT-RECHECK-SAVED\":') == 1 else None"
mut "E5 the handler runs coldLockEvictCheck" coldlock_evict.go \
  "inh('\tsealMu.Lock()', '\tcoldLockEvictCheck(dest, uid)\n\tsealMu.Lock()')"
mut "E6 the verb added to concurrentSafeCmd" main.go \
  "s.replace('\tcase \"POLL-REAP\", \"ACK-REAP\",', '\tcase \"EVICT-RECHECK-SAVED\", \"POLL-REAP\", \"ACK-REAP\",', 1) if s.count('\tcase \"POLL-REAP\", \"ACK-REAP\",') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
