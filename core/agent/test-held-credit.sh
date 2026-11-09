#!/usr/bin/env bash
# test-held-credit.sh [--mutate] -- runs held_credit_test.go (NWP-20261128-31): walletHoldsCredit (wallet_restore.go)
# is the unspent balance, so an activated plan (PlanGB > 0 for good, its tokens spent) is not credit a lost publish
# loses, and neither a no-keep cold-lock sign-out nor GET-PARKED-CREDIT tells the gate it is lost. --mutate re-runs it
# against copies of wallet_restore.go with the predicate broken in turn, injected with `go test -overlay`, so the
# source tree is never edited. Each mutant must be CONVICTED by a `--- FAIL` line of each test it names; one that does
# not apply, does not compile, or fails without those lines counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestHeldCredit_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <space-separated --- FAIL names it must show> <python-regex pattern> <replacement>
  local label="$1" want="$2" m="$W/mut.go" ov="$W/overlay.json" out n missing=""
  python3 - wallet_restore.go "$m" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
s,c=re.subn(pat,lambda _m:_m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/wallet_restore.go" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$("${RUN[@]:0:3}" -overlay "$ov" "${RUN[@]:3}" 2>&1)
  for n in $want; do
    grep -q -- "--- FAIL: $n " <<<"$out" || missing="$missing $n"
  done
  if [ -z "$missing" ]; then
    echo "  convicted $label:$(printf ' %s' $want)"
  elif grep -q -- '--- FAIL' <<<"$out"; then
    echo "  SURVIVED  $label -- no --- FAIL for:$missing"; grep -- '--- FAIL' <<<"$out"; fails=$((fails+1))
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; tail -15 <<<"$out"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
# Every pattern anchors on walletHoldsCredit's own unreadable-file arm, so none can hit another function.
A='(func walletHoldsCredit\(wp string\) bool \{.*?if err != nil \{\n\t\treturn )true(\n\t\}\n\treturn )w\.balance\(\) > 0\n\}'
mut "K1 an activated plan counts as credit again" \
  'TestHeldCredit_Table TestHeldCredit_AnActivePlanIsNotToldLost TestHeldCredit_ParkedActivePlanIsNotLost' \
  "$A" $'\\1true\\2w.balance() > 0 || w.PlanGB > 0\n}'
mut "K2 an unreadable wallet counts as no credit" \
  'TestHeldCredit_Table TestHeldCredit_Table/a_directory_at_the_path TestHeldCredit_Table/unparsable_JSON' \
  "$A" $'\\1false\\2w.balance() > 0\n}'
mut "K3 only a waiting plan counts as credit" \
  'TestHeldCredit_Table TestHeldCredit_Table/a_plan_with_7_tokens,_short_of_its_price TestHeldCredit_Table/one_blind_token' \
  "$A" $'\\1true\\2w.planPending()\n}'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
