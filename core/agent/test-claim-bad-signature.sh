#!/usr/bin/env bash
# test-claim-bad-signature.sh [--mutate] -- runs claim_bad_signature_test.go, claim_one_save_test.go and
# blindrsa/blindrsa_finalize_test.go (NWP-20261122-16: a /issue 200 whose signatures do not land -- refused by
# Finalize, one short, or not base64 -- records no plan and appends no token; Finalize refuses a signature it cannot
# verify. NWP-20261128-24: a batch's plan and its tokens land in one save or not at all). --mutate re-runs them against
# copies of billing.go / blindrsa/blindrsa.go with each guard broken in turn, injected with `go test -overlay`, so the
# source tree is never edited: M1 drainClaim records the plan from a batch whose signatures were refused, M2 issueBatch
# ignores Finalize's error, M3 Finalize returns without verifying (run in BOTH packages, convicted in each), M4 the
# plan saved before the tokens, in two writes, M5 applyPlanMode after the append. Each run
# must be CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL line counts
# as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
MAIN_RUN=(-timeout 120s -run 'ClaimBadSignature|ClaimOneSave' .)
RSA_RUN=(-timeout 120s -run 'Finalize' ./blindrsa/)

out=$(go test -count=1 "${MAIN_RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
out=$(go test -count=1 "${RSA_RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <pkg: main|blindrsa|both> <python-regex pattern> <replacement>
mut() {
  local label="$1" src="$2" pkgs="$3" m="$W/mut.go" ov="$W/overlay.json" out pkg
  local -a run
  python3 - "$src" "$m" "${@:4}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
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
  if ! out=$(go vet -overlay "$ov" . ./blindrsa/ 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  [ "$pkgs" = both ] && pkgs="main blindrsa"
  for pkg in $pkgs; do
    if [ "$pkg" = main ]; then run=("${MAIN_RUN[@]}"); else run=("${RSA_RUN[@]}"); fi
    out=$(go test -count=1 -overlay "$ov" "${run[@]}" 2>&1)
    if grep -q -- '--- FAIL' <<<"$out"; then
      echo "  convicted $label [$pkg]"
    elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
      echo "  NOFAIL-LINE $label [$pkg] -- failed without a --- FAIL line"; fails=$((fails+1))
    else
      echo "  SURVIVED  $label [$pkg]"; fails=$((fails+1))
    fi
  done
}
# M1 drops err == nil from BOTH guards: dropped from record alone, a refused batch still never reaches recordClaimBatch.
mut "M1 drainClaim records the plan from a refused batch" billing.go main \
  'record := !planned && err == nil && code == http\.StatusOK && plan\.Periods > 0' \
  'record := !planned && code == http.StatusOK && plan.Periods > 0' \
  'if err == nil && code == http\.StatusOK \{(?=\n\t+perr = recordClaimBatch\()' \
  'if code == http.StatusOK {'
mut "M2 issueBatch ignores Finalize's error" billing.go main \
  '\n\t\tif err != nil \{\n\t\t\treturn nil, res, code, fmt\.Errorf\("issue: finalize/verify failed: %w", err\)\n\t\t\}' \
  '
		_ = err'
mut "M3 Finalize returns without verifying" blindrsa/blindrsa.go both \
  '\n\tif err := Verify\(pub, msg, sigBytes\); err != nil \{\n\t\treturn nil, err\n\t\}' \
  ''
mut "M4 the plan saved before the tokens, in two writes" billing.go main \
  'perr = recordClaimBatch\(walletPath, record, plan\.Periods, plan\.GB, mode, toks\)' \
  'if record { perr = recordPlanMode(walletPath, plan.Periods, plan.GB, mode) }; if perr == nil { perr = appendTokens(walletPath, toks) }'
mut "M5 applyPlanMode after the append" billing.go main \
  '\tif record \{\n\t\tapplyPlanMode\(w, periods, gb, mode\)\n\t\}\n\tw\.BlindTokens = append\(w\.BlindTokens, toks\.\.\.\)\n' \
  $'\tw.BlindTokens = append(w.BlindTokens, toks...)\n\tif record {\n\t\tapplyPlanMode(w, periods, gb, mode)\n\t}\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
