#!/usr/bin/env bash
# test-plan-carry-chain.sh [--mutate] -- a chained passphrase change keeps its intermediate key in !bill-mid and the
# sign-in retry asks it too (NWP-20261103-01, Q147). Plain: the focused set. --mutate copies the package into the temp
# root for every mutant, applies the mutant to THAT copy and runs the same set there; each must be CONVICTED by a
# `--- FAIL`. The working tree is never edited. A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='PlanCarryChain|BillingRecord|CarryRecord|SettledCarry|UnsettledRecord|CarriesThePlan|RefusalIsNot|IsUnresolvable|RetagRecord'
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
P=TestPlanCarryChain
mut "M1 the key moved off is not recorded" scope_repoint.go $'\t\tadd(billKeyOf(idx))\n' '' "${P}ReachesTheIntermediateKey" "${P}RetryMovesEveryKeyThatHoldsAGrant"
mut "M2 the retry skips the mid keys" main.go 'range append([]string{prev}, mid...)' 'range []string{prev}' "${P}ReachesTheIntermediateKey" "${P}RetryMovesEveryKeyThatHoldsAGrant"
mut "M3 dropBillPrev leaves !bill-mid" main.go $'\t\tdelete(cidx, scopeBillMidKey)\n' '' "${P}ReachesTheIntermediateKey"
mut "M4 the key moved to is recorded" scope_repoint.go $'\t\tadd(billKeyOf(idx))\n' $'\t\tadd(billKeyOf(idx))\n\t\tmid = append(mid, newBill)\n' "${P}BackToAWritesNoMidNamingA"
mut "M5 isScopeSuffix does not exclude !bill-mid" scope_index.go ' && k != scopeBillMidKey' '' "${P}MidRecordIsUnresolvableByAnOlderBuild"
mut "M6 the retry stops at the first success" main.go $'clear = true // rule 3: confirmed at the gateway; the other keys are still asked' $'clear = true\n\t\t\t\tbreak' "${P}RetryMovesEveryKeyThatHoldsAGrant"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
