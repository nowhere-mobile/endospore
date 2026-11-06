#!/usr/bin/env bash
# test-lost-start-recovery.sh [--mutate] -- runs lost_start_recovery_test.go (NWP-20261021-14); --mutate re-runs it
# against main.go with each part of runWorkerHeld's #83 recovery broken in turn, restoring the file on exit. Each mutant
# must be CONVICTED by the named test's failure; one that fails to apply, or fails to compile, counts as a failure.
# There is no mutant for the recovery's `res` absent check: a non-empty res is read and returned earlier in the same
# tick, so that condition is redundant and no test could tell it from its removal.
set -uo pipefail
cd "$(dirname "$0")"
MAIN=main.go
RUN=(go test -count=1 -run '^TestLostStartRecovery_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | tail -5
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d)
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <expected failing test> <python-regex pattern> <replacement>
  local res
  python3 - "$MAIN" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $2"* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "M1 the pending-request condition removed" TestLostStartRecovery_ConsumedRequestIsNeverRerun \
  'if _, err := os\.Stat\(req\); err == nil \{(\n\t+if workerState\(lane\.svc\) == "stopped")' 'if true {\1'
mut "M2 re-fire in any state" TestLostStartRecovery_HungInstanceExpires \
  'workerState\(lane\.svc\) == "stopped"' 'workerState(lane.svc) == "stopped" || true'
mut "M3 noteLostStart removed" TestLostStartRecovery_LostStartIsRefired \
  '(\t+workerStart\(lane\.svc\)\n)\t+noteLostStart\(op\)\n' '\1'
mut "M4 the re-fire's start removed, the count kept" TestLostStartRecovery_LostStartIsRefired \
  '\t+workerStart\(lane\.svc\)\n(\t+noteLostStart\(op\)\n)' '\1'
mut "M5 the state compared with running (ordering)" TestLostStartRecovery_LostStartIsRefired \
  'workerState\(lane\.svc\) == "stopped"' 'workerState(lane.svc) == "running"'
mut "M5 the state compared with running (hung)" TestLostStartRecovery_HungInstanceExpires \
  'workerState\(lane\.svc\) == "stopped"' 'workerState(lane.svc) == "running"'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
