#!/usr/bin/env bash
# test-claim-plan-change.sh [--mutate] -- runs claim_plan_change_test.go (NWP-20261031-10: CLAIM2 records the customer's
# convert-or-keep answer with the purchase, and its activation lease sends plan_change "keep" or, since NWP-20261125-12
# (h51 #5), "convert"; plain CLAIM sends none); --mutate re-runs it against copies of billing.go / main.go /
# wallet_restore.go with each guard broken in turn, injected with `go test -overlay`, so the source tree is
# never edited. Each mutant must be CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies
# without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'ClaimPlanChange' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label="$1" src="$2" m="$W/mut.go" ov="$W/overlay.json" out pin=""
  [ "$src" = main.go ] && pin="$m"
  python3 - "$src" "$m" "${@:3}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst=sys.argv[1:3]
rest=sys.argv[3:]
s=open(src).read()
for pat,rep in zip(rest[0::2],rest[1::2]):
    s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(NOWHERE_PIN_MAIN_GO="$pin" go test -count=1 -overlay "$ov" -run 'ClaimPlanChange' . 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "M1 the mode dropped in drainClaimMode" billing.go 'recordClaimBatch\(walletPath, record, plan\.Periods, plan\.GB, mode, toks\)' 'recordClaimBatch(walletPath, record, plan.Periods, plan.GB, "", toks)'
mut "M2 keep sent on every paid lease" billing.go 'if w\.PlanKeep \{\n\t\treturn planChangeKeep\n\t\}\n\tif w\.PlanConvert \{\n\t\treturn planChangeConvert\n\t\}\n\treturn ""' 'return planChangeKeep'
mut "M3 planActivated loses the choice on promotion" billing.go 'w\.PlanKeep = next\.GB, next\.Periods, next\.Keep' 'w.PlanKeep = next.GB, next.Periods, false'
mut "M4 a bad mode drains the claim" main.go 'if mode != "convert" && mode != planChangeKeep \{' 'if false {'
mut "M5 planChange never returns convert" billing.go 'if w\.PlanConvert \{\n\t\treturn planChangeConvert\n\t\}\n\t' ''
mut "M6 CLAIM2 convert passed as no answer" main.go 'handleClaimMode\(conn, dest, strings\.TrimRight\(c, "\\r\\n"\), mode\)' 'handleClaimMode(conn, dest, strings.TrimRight(c, "\r\n"), strings.TrimPrefix(mode, "convert"))'
mut "M7 planActivated drops Convert" billing.go '\n\tw\.PlanConvert = next\.Convert' ''
mut "M8 mergeLateRestore drops Convert" wallet_restore.go ', Convert: w\.PlanConvert\}' '}'
mut "M9 the duplicate check ignores Convert" billing.go ' \|\| last\.Convert != convert \{' ' {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
