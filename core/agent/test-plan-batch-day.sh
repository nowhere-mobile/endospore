#!/usr/bin/env bash
# test-plan-batch-day.sh [--mutate] -- NWP-20261102-12: a plan starts on a shared batch day (Q134 defence 3,
# docs/billing-plan-model.md). Runs the focused Go tests; --mutate applies each mutant to a pristine copy of billing.go
# (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a
# failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp billing.go "$W/billing.go.orig" || exit 2
trap 'cp "$W/billing.go.orig" billing.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestPlanBatch_"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new>: replace the first <old> in a pristine billing.go, require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" res
  cp "$W/billing.go.orig" billing.go
  if ! OLD="$old" NEW="$new" python3 -c "
import os
s = open('billing.go').read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open('billing.go','w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "B1 rounding removed" '	if batch {' '	if false {'
mutate "B2 rounds down" 'e += planBatchEpochs - r' 'e -= r'
mutate "B3 planActivated keeps the raw jitter" '	w.ActivateAfter = activationHold()
}

' '	w.ActivateAfter = nowEpoch() + jitterEpochs()
}

'
mutate "B4 the override-0 case is rounded" '			batch = false' '			batch = true'
mutate "B5 the over-free override bypassed" 'if w.ActivateAfter > nowEp && !overFree {' 'if w.ActivateAfter > nowEp {'
cp "$W/billing.go.orig" billing.go
[ "$FAILS" -eq 0 ] || { echo "== $FAILS mutant(s) not convicted"; exit 1; }
echo "== all mutations convicted"
