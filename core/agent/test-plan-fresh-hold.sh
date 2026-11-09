#!/usr/bin/env bash
# test-plan-fresh-hold.sh [--mutate] -- a later purchase waits its own activation hold (NWP-20261129-05, Q134): a
# purchase recorded with nothing waiting gets a fresh hold once the stored one has passed; a running hold stays, and a
# queued purchase never moves the hold of the purchase it waits behind.
# Plain: the focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT
# copy and runs the same focused set there; each must be CONVICTED by the named `--- FAIL` tests. The working tree is
# never edited. A mutant that fails to apply (its literal must occur exactly once) or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='PlanFreshHold|PlanBatch_|WalletPlanQueue'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>... (old must occur exactly once)
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want d
  shift 4
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R "$SRC/." "$d/"
  python3 - "$d/$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(cd "$d" && go test -count=1 -run "$FOCUS" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  rm -rf "$d"
}
F1=TestPlanFreshHold_ALaterPurchaseWaitsItsOwnHold
F2=TestPlanFreshHold_AHoldEndingNowIsFinished
F3=TestPlanFreshHold_ARunningHoldIsKept
F4=TestPlanFreshHold_AWaitingPurchasesPassedHoldStays
F5=TestPlanFreshHold_ThroughCapFlush
REPLACE='if w.ActivateAfter <= nowEpoch() {'
QUEUE='if w.ActivateAfter == 0 {'
mut "H1 the replace branch back on zero" billing.go "$REPLACE" "$QUEUE" "$F1" "$F2" "$F5"
mut "H2 a hold ending now still counts as running" billing.go "$REPLACE" 'if w.ActivateAfter < nowEpoch() {' "$F2"
mut "H3 the replace branch always re-draws" billing.go "$REPLACE" 'if true {' "$F3" TestPlanBatch_RecordPlanStoresABatchDay
mut "H4 the passed-hold rule in the queue branch too" billing.go "$QUEUE" "$REPLACE" "$F4"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
