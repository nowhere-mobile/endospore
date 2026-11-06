#!/usr/bin/env bash
# test-wallet-plan-queue.sh [--mutate] -- NWP-20261031-07: the wallet activates each purchase at its own size and term
# (docs/product-decisions.md "a bigger plan starts at once ..."). Runs the focused Go tests; --mutate applies each mutant
# to pristine copies of billing.go / wallet_restore.go / main.go (restored on exit) and requires a real `--- FAIL`: a mutant that
# does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp billing.go "$W/billing.go.orig" || exit 2
cp wallet_restore.go "$W/wallet_restore.go.orig" || exit 2
cp main.go "$W/main.go.orig" || exit 2
trap 'cp "$W/billing.go.orig" billing.go; cp "$W/wallet_restore.go.orig" wallet_restore.go; cp "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="WalletPlanQueue|RecordPlan|LearningNever|TwoWriters_AStale"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <old> <new>: replace the first <old> in a pristine copy of <file>, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" old="$3" new="$4" res
  cp "$W/billing.go.orig" billing.go
  cp "$W/wallet_restore.go.orig" wallet_restore.go
  cp "$W/main.go.orig" main.go
  if ! F="$f" OLD="$old" NEW="$new" python3 -c "
import os
f = os.environ['F']
s = open(f).read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "Q1 recordPlan maxes again" billing.go '		w.PlanGB, w.PlanPeriods, w.PlanKeep = gb, periods, keep
' '		if gb > w.PlanGB {
			w.PlanGB = gb
		}
		if periods > w.PlanPeriods {
			w.PlanPeriods = periods
		}
		w.PlanKeep = keep
'
mutate "Q2 planActivated never pops" billing.go '	w.PlanQueue = append([]PlanSpec(nil), w.PlanQueue[1:]...)' '	_ = w.PlanQueue'
mutate "Q3 walletForPublish maxes over a waiting purchase" billing.go 'if !local.planPending() && len(local.PlanQueue) == 0 {' 'if true {'
mutate "Q4 the duplicate check dropped" billing.go 'if last.GB != gb || last.Periods != periods || last.Keep != keep || last.Convert != convert {' 'if last.GB != gb || last.Periods != periods || last.Keep != keep || last.Convert != convert || true {'
mutate "Q5 promotion leaves ActivateAfter at 0" billing.go '	w.ActivateAfter = activationHold()
}

' '	w.ActivateAfter = 0
}

'
mutate "Q6 a late restore orders the session first" wallet_restore.go 'for _, w := range []*Wallet{stored, local} {' 'for _, w := range []*Wallet{local, stored} {'
mutate "Q7 the cap fold publishes the pre-promotion wallet" billing.go '	c := *w
	c.planActivated()
	return &c' '	c := *w
	return &c'
cp "$W/billing.go.orig" billing.go
cp "$W/wallet_restore.go.orig" wallet_restore.go
mutate "Q8 a grace lease leaves the speculative promotion published" main.go 'if promoted != nil && len(plain)+len(blind) > 0 && pcode' 'if false && promoted != nil && len(plain)+len(blind) > 0 && pcode'
cp "$W/billing.go.orig" billing.go
cp "$W/wallet_restore.go.orig" wallet_restore.go
cp "$W/main.go.orig" main.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
