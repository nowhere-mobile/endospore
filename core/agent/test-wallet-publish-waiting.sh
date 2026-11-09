#!/usr/bin/env bash
# test-wallet-publish-waiting.sh [--mutate] -- a wallet publish keeps the other handset's waiting purchase whole
# (NWP-20261129-10; decided 2026-10-20: a smaller purchase is never stranded, and Q107): walletForPublish on an idle
# phone publishes the stored copy's waiting purchase, answer and queue when the tokens carried fund it.
# Plain: the focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT
# copy and runs the same focused set there; each must be CONVICTED by the named `--- FAIL` of each test. The working
# tree is never edited. A mutant that fails to apply (its literal must occur exactly once) or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='WalletPublishWaiting|WalletPublish_|WalletPlanQueue'
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
P1=TestWalletPublishWaiting_TheOtherPhonesTopUpIsPublishedWhole
P2=TestWalletPublishWaiting_AQueueAndAConvertAnswerRideAlong
P3=TestWalletPublishWaiting_TokensThisPhoneHeld
P6=TestWalletPublishWaiting_ThroughADurablePublish
P7=TestWalletPublishWaiting_ACarriedShortfallKeepsTodaysMax
mut "M1 the new branch is never taken" billing.go \
  'if carried > 0 && ' 'if false && carried > 0 && ' "$P1" "$P2" "$P6"
mut "M2 PlanQueue is not carried" billing.go \
  'out.PlanQueue = append([]PlanSpec(nil), stored.PlanQueue...)' '_ = stored.PlanQueue' "$P2"
mut "M3 PlanKeep and PlanConvert are not carried" billing.go \
  'out.PlanKeep, out.PlanConvert = stored.PlanKeep, stored.PlanConvert' '_, _ = stored.PlanKeep, stored.PlanConvert' "$P1" "$P2"
mut "M4 the carried > 0 condition is dropped" billing.go \
  'if carried > 0 && ' 'if carried >= 0 && ' "$P3"
mut "M5 the funding check is dropped" billing.go \
  ' && out.balance() >= stored.PlanGB*int(stored.PlanPeriods)' '' "$P7"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
