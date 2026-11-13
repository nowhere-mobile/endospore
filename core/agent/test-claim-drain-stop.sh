#!/usr/bin/env bash
# test-claim-drain-stop.sh [--mutate] -- runs claim_drain_stop_test.go (NWP-20261129-43: a claim drain cut short by an
# error or an unexpected status, after some tokens landed, writes one counts-only stop line with a fixed reason; a
# complete drain and an unknown code write none).
# Plain: the focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT
# copy and runs the same focused set there; each must be CONVICTED by the named `--- FAIL` of every test it lists. The
# working tree is never edited. A mutant that fails to apply (its literal must occur exactly once) or to compile is a
# failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='ClaimDrainStop'
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
S1=TestClaimDrainStop_S1_NoAnswer
S2=TestClaimDrainStop_S2_SignaturesRefused
S3=TestClaimDrainStop_S3_UnexpectedStatus
S4=TestClaimDrainStop_S4_CompleteOrUnknownWritesNone
S5=TestClaimDrainStop_S5_NamesNoCodeOrToken
mut "K1 the err-arm line removed" billing.go \
  'logClaimDrainStop(total, claimDrainErrWhy(code))' '' "$S1" "$S2"
mut "K2 the default-arm line removed" billing.go \
  'logClaimDrainStop(total, fmt.Sprintf("HTTP %d", code))' '' "$S3"
mut "K3 the line also written at the final 402" billing.go \
  'return total, false, nil // nothing left to claim -> done' \
  'logClaimDrainStop(total, "done"); return total, false, nil // nothing left to claim -> done' "$S4"
mut "K4 the code added to the line" billing.go \
  'logClaimDrainStop(total, claimDrainErrWhy(code))' \
  'logClaimDrainStop(total, claimDrainErrWhy(code)+" "+claim)' "$S5"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
