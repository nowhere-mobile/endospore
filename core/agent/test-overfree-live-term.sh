#!/usr/bin/env bash
# test-overfree-live-term.sh [--mutate] -- NWP-20261201-25: planPurchase skips the Q134 activation hold only for a
# profile over the free allowance with no live bought term (PaidThrough <= now, h60 #13). Runs the focused Go tests;
# --mutate applies each mutant to a pristine copy of billing.go (restored on exit) and requires a real `--- FAIL` of
# the test that names it: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp billing.go "$W/billing.go.orig" || exit 2
trap 'cp "$W/billing.go.orig" billing.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestOverFreeLiveTerm_|TestJitter|TestPlanBatch_OverFreeStartsAtOnce'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new> <test>: replace the first <old> in a pristine billing.go, require a real --- FAIL of <test>
mutate() {
  local lbl="$1" old="$2" new="$3" test="$4" res
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
  if grep -q -- "--- FAIL: $test " <<<"$res"; then echo "  convicted $lbl by $test"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl -- $test did not fail"; FAILS=$((FAILS+1)); fi
}
BYPASS='atRisk := overFree && w.PaidThrough <= nowEp'
HOLD='if w.ActivateAfter > nowEp && !atRisk {'
mutate "V1 term check dropped" "$BYPASS" 'atRisk := overFree' TestOverFreeLiveTerm_ALiveTermWaitsOutTheHold
mutate "V2 a term ending now counts as live" "$BYPASS" 'atRisk := overFree && w.PaidThrough < nowEp' TestOverFreeLiveTerm_TermEndingNowCountsAsNone
mutate "V3 bypass removed" "$BYPASS" 'atRisk := false' TestOverFreeLiveTerm_NoTermStartsAtOnce
mutate "V4 a live term blocks after the hold" "$HOLD" 'if (w.ActivateAfter > nowEp || w.PaidThrough > nowEp) && !atRisk {' TestOverFreeLiveTerm_ALiveTermStartsOnceTheHoldEnds
mutate "V5 hold ignored under the free tier" "$BYPASS" 'atRisk := true' TestOverFreeLiveTerm_UnderFreeHoldsEitherWay
cp "$W/billing.go.orig" billing.go
[ "$FAILS" -eq 0 ] || { echo "== $FAILS mutant(s) not convicted"; exit 1; }
echo "== all mutations convicted"
