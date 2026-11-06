#!/usr/bin/env bash
# test-rekey-backup.sh [--mutate] -- the background re-key yields to a manual backup and never waits for the worker
# slot (NWP-20261027-17). Plain: the re-key tests. --mutate applies each mutant to scope_rekey_job.go in place (a
# pristine copy lives in one temp root, restored after every mutant and on exit) and runs the new tests; each must be
# CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
restore() { [ -f "$W/scope_rekey_job.go" ] && cp -f "$W/scope_rekey_job.go" scope_rekey_job.go; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -timeout 300s -run 'TestRekeyOnce|TestARekeyBatch|TestHoldingTheWorkerSlot|TestLargeScopeRekey' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp scope_rekey_job.go "$W/scope_rekey_job.go"
fails=0
A=TestRekeyOnceStandsDownWhileAManualBackupHoldsTheSealChannel
B=TestARekeyBatchLeavesNoReasonForBackupToRefuse
D=TestRekeyOnceDoesNotWaitForAHeldSlot
# mut <label> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" old="$2" new="$3" res want
  shift 3
  python3 - scope_rekey_job.go "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -timeout 120s -run 'TestRekeyOnceStandsDownWhileAManualBackup|TestARekeyBatch|TestRekeyOnceDoesNotWait' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "R1 sealInFlight dropped from the stand-down" $'busy := sealInFlight || pendingReapUID' $'busy := pendingReapUID' $A
mut "R2 a batch sets sealInFlight and never clears it" $'\tdefer func() { <-laneRW.slot }()\n\trekeyStateMu.Lock()\n\tif rekeyStateUID' $'\tdefer func() { <-laneRW.slot }()\n\tpendingReapMu.Lock()\n\tsealInFlight = true\n\tpendingReapMu.Unlock()\n\trekeyStateMu.Lock()\n\tif rekeyStateUID' $B
mut "R3 the slot try made blocking" $'\tselect {\n\tcase laneRW.slot <- struct{}{}:\n\tdefault:\n\t\treturn\n\t}\n\tdefer func() { <-laneRW.slot }()' $'\tlaneRW.slot <- struct{}{}\n\tdefer func() { <-laneRW.slot }()' $D
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
