#!/usr/bin/env bash
# test-plan-moving.sh [--mutate] -- a credential change that leaves the plan carry unsettled stamps its !bill-prev
# record and GET-BILLING says moving= while the rebind cooldown can still be refusing it (NWP-20261103-05, Q147).
# Plain: the focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT
# copy and runs the same set there; each must be CONVICTED by a `--- FAIL`. The working tree is never edited. A mutant
# that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='PlanMoving'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
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
P=TestPlanMoving
mut "V1 At not stamped" scope_repoint.go 'At: planMovingNow()}' '}' "${P}RefusedRotationStampsTheRecordAndBillingSaysMoving"
mut "V2 the window check removed" billing.go 'if now >= at+rebindCooldownEpochs*billingEpochSeconds+billingEpochSeconds {' 'if false {' "${P}WindowEnds"
mut "V3 a settle leaves the marker" main.go $'\tclearPlanMoving(walletPath)\n\tdropBillPrevGuarded(base, name, pass, dk, mayWrite)' $'\tdropBillPrevGuarded(base, name, pass, dk, mayWrite)' "${P}SignInRetryThatSettlesRemovesTheMarker"
mut "V3b a settling rotation leaves the marker" main.go $'\t\tif walletOurs {\n\t\t\tclearPlanMoving(capWalletPath())\n\t\t}\n' '' "${P}SettledRotationClearsAnEarlierMarker"
mut "V4 removeWallet leaves the marker" wallet_lock.go $'\tos.Remove(planMovingPath(walletPath)) // NWP-20261103-05: the plan-moving notice never outlives the session\n' '' "${P}RemoveWalletRemovesTheMarker"
mut "V5 the marker is written when walletOurs is false" main.go '	} else if walletOurs {
		// NWP-20261103-05 (Q147): the carry' '	} else {
		// NWP-20261103-05 (Q147): the carry' "${P}WalletNotOursWritesNoMarker"
mut "V6 a record naming only the current key reads as moving" billing.go 'if billPrevOf(idx) == cur && len(billMidOf(idx)) == 0 {' 'if false {' "${P}SamePassphraseIsNotMoving"
mut "V7 a same-passphrase rotation notes the marker" main.go 'rotPrevAt = billMovingSince(nidx, newV2)' 'rotPrevAt = billPrevAtOf(nidx)' "${P}SamePassphraseIsNotMoving"
mut "V8 a same-passphrase sign-in keeps the marker" main.go 'notePlanMoving(walletPath, billMovingSince(idx, profileRefV2(name, pass)))' 'notePlanMoving(walletPath, billPrevAtOf(idx))' "${P}SamePassphraseIsNotMoving"
mut "V9 a mid key no longer keeps a change back moving" billing.go 'if billPrevOf(idx) == cur && len(billMidOf(idx)) == 0 {' 'if billPrevOf(idx) == cur {' "${P}ChangeBackWithAMidKeyStaysMoving"
mut "V10 an old == new guard at the rotation wipes a still-valid marker" main.go 'rotPrevAt = billMovingSince(nidx, newV2)' $'rotPrevAt = billPrevAtOf(nidx)\n\t\tif oldV2 == newV2 {\n\t\t\trotPrevAt = 0\n\t\t}' "${P}SamePassphraseAfterARefusedChangeStaysMoving"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
