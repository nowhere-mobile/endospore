#!/usr/bin/env bash
# test-plan-run-order.sh [--mutate] -- runs plan_run_order_test.go (NWP-20261120-10, h48 #9: the agent learns the
# gateway's plans in run order into the display-only Wallet.AccountPlans, and GET-BILLING ships the live steps as
# plans=); --mutate re-runs it against copies of billing.go / wallet_restore.go with each guard broken in turn,
# injected with `go test -overlay`, so the source tree is never edited. Each mutant must be CONVICTED by a real
# `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestPlanRunOrder' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label="$1" src="$2" m ov out rc
  m=$(mktemp -p "$W" mut.XXXXXX) || exit 2
  ov=$(mktemp -p "$W" overlay.XXXXXX) || exit 2
  python3 - "$src" "$m" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run 'TestPlanRunOrder' . 2>&1); rc=$?
  score_mutant "$label" "$rc" "$out" || fails=$((fails+1))
}
mut "A1 an absent list clears the stored one" billing.go 'if planStepsValid\(info\.Plans\) \{' $'w.AccountPlans = nil\n\tif planStepsValid(info.Plans) {'
mut "A2 emitted with one step" billing.go 'len\(steps\) >= 2' 'len(steps) >= 1'
mut "A3 ended steps kept" billing.go 'if s\.ThroughEpoch >= now \{' 'if true {'
mut "A4 emitted while pending" billing.go 'if !w\.planPending\(\) \{\n\t\tif steps :=' $'if true {\n\t\tif steps :='
mut "A5 the restore merge drops local's list" wallet_restore.go 'out\.AccountPlans = local\.AccountPlans' 'out.AccountPlans = nil'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
