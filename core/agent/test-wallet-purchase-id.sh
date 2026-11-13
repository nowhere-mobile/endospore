#!/usr/bin/env bash
# test-wallet-purchase-id.sh [--mutate] -- two phones' waiting purchases are both kept (NWP-20261201-18; decided
# 2026-11-06, h60 #14): each recorded purchase carries a random id, sealed in the wallet and never sent to the gateway,
# and a wallet publish queues every waiting purchase of the stored copy that this session never held.
# Plain: the focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT
# copy and runs the same focused set there; each must be CONVICTED by the named `--- FAIL` of each test. The working
# tree is never edited. A mutant that fails to apply (its literal must occur exactly once) or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='WalletPurchaseID|WalletPublishWaiting|WalletPlanQueue'
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
s = open(p, encoding='utf-8').read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
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
TWO=TestWalletPurchaseID_TwoPhonesWaitingPurchasesAreBothKept
IDLE=TestWalletPurchaseID_AnIdlePhoneQueuesBothOfTheOthers
ACTIVATED=TestWalletPurchaseID_APurchaseActivatedHereIsNotResurrected
OWN=TestWalletPurchaseID_ThisPhonesOwnPurchaseIsNotDuplicated
MINT=TestWalletPurchaseID_IdsAreMintedPerRecordedPurchase
SEEN=TestWalletPurchaseID_TheSeenSetHoldsPlanIDs
LATE=TestWalletPurchaseID_ALateRestoreDedupsByID
FOLD=TestWalletPurchaseID_TheCapFoldCopiesPlanID
LEASE=TestWalletPurchaseID_NoLeaseFieldCarriesAnID
OLD=TestWalletPurchaseID_AStoredPurchaseWithoutAnIDTakesTheOldArm
MIXED=TestWalletPurchaseID_ASeenQueueIDLeavesTheOlderHead
TOOK=TestWalletPurchaseID_AnUnseenQueueIDStopsTheOlderRule
RANDFAIL=TestWalletPurchaseID_AFailedRandomSourceRecordsThePurchaseWithoutAnID
TAKE='if k := "p:" + s.ID; !have[k] && !seen[k] {'
mut "M1 the queue arm mints no id" billing.go 'PlanSpec{ID: newPurchaseID(), GB: gb' 'PlanSpec{GB: gb' "$MINT"
mut "M2 the replace arm mints no id" billing.go 'w.PlanID = newPurchaseID()' '_ = newPurchaseID()' "$MINT"
mut "M3 the id arm is never taken" billing.go "$TAKE" 'if k := "p:" + s.ID; false && !have[k] && !seen[k] {' "$TWO" "$IDLE"
mut "M4 the seen check is dropped" billing.go "$TAKE" 'if k := "p:" + s.ID; !have[k] {' "$ACTIVATED"
mut "M5 the local-held check is dropped" billing.go "$TAKE" 'if k := "p:" + s.ID; !seen[k] {' "$OWN"
mut "M6 the taken head keeps this phone's id" billing.go 'head.Convert, head.ID' 'head.Convert, out.PlanID' "$IDLE"
mut "M7 the queue is not a fresh slice" billing.go 'queue := append([]PlanSpec(nil), local.PlanQueue...)' 'queue := local.PlanQueue' "$TWO"
mut "M8 the older rule fires on a stored copy with an id" billing.go ' && !took && olderRule {' ' && !took && (olderRule || true) {' "$ACTIVATED" "$MIXED"
mut "M9 the older rule keeps this phone's id" billing.go $'\t\t\tout.PlanID = stored.PlanID\n' '' "$OLD"
mut "M17 the older rule fires when the ids took a purchase" billing.go ' && !took && olderRule {' ' && olderRule {' "$TOOK"
mut "M18 a seen queue id stops the older rule" billing.go 'olderRule := idless && ' 'olderRule := idless && len(stored.PlanQueue) == 0 && ' "$MIXED"
mut "M19 the older rule restores a seen queue id" billing.go 'if q.ID == "" {' 'if true {' "$MIXED"
mut "M20 the older rule ignores a queue with no id-less entry" billing.go 'olderRule := idless && ' 'olderRule := (idless || true) && ' "$MIXED"
mut "M21 the older rule ignores a waiting head with an id" billing.go '(!stored.planPending() || stored.PlanID == "")' '(!stored.planPending() || stored.PlanID == "" || true)' "$ACTIVATED"
mut "M10 planActivated drops the id" billing.go $'\tw.PlanID = next.ID\n' '' "$MINT" "$TWO"
mut "M11 the seen keys drop the head id" wallet_seen.go 'keys = append(keys, "p:"+w.PlanID)' '_ = w.PlanID' "$SEEN"
mut "M12 the seen keys drop the queue ids" wallet_seen.go 'keys = append(keys, "p:"+q.ID)' '_ = q.ID' "$SEEN"
mut "M13 the late restore dedup is dropped" wallet_restore.go 'if s.ID != "" && haveID[s.ID] {' 'if false {' "$LATE"
mut "M14 the late restore drops the head id" wallet_restore.go $'\t\tout.PlanID = waiting[0].ID\n' '' "$LATE"
mut "M15 leaseReq gains the id" billing.go $'type leaseReq struct {\n' $'type leaseReq struct {\n\tPlanID string `json:"plan_id"`\n' "$LEASE"
mut "M22 a failed read still mints an id" billing.go $'recorded without one (h60 #14)")\n\t\treturn ""\n' $'recorded without one (h60 #14)")\n\t\treturn hex.EncodeToString(b)\n' "$RANDFAIL"
mut "M23 a failed read logs the reader's error" billing.go 'recorded without one (h60 #14)")' 'recorded without one (h60 #14)", err)' "$RANDFAIL"
mut "M16 the cap fold drops the id" main.go $'\t\t\t\t\tw.PlanID = promoted.PlanID\n' '' "$FOLD"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
