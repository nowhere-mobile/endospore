#!/usr/bin/env bash
# test-settle-payment.sh [--mutate] -- runs settle_payment_test.go (NWP-20261128-27: settlePayment returns, by
# identity, the unspent TAIL of plain-then-blind, the gateway's own charging order -- nowhere-cloud collectTokens)
# with TestLeaseRestoresUnspentTokens beside it; --mutate re-runs them against copies of billing.go with
# settlePayment broken in turn, injected with `go test -overlay`, so the source tree is never edited. Each mutant
# must be CONVICTED by a `--- FAIL: <test>` line for EVERY test named beside it; one that does not apply, does not
# compile, or fails without those named lines counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='SettlePayment|LeaseRefs_ADeltaLease|LeaseRestoresUnspentTokens'

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P1=TestSettlePayment_ReturnsTheUnspentTailPlainFirst
P2=TestSettlePayment_ABlindOnlyAndAPlainOnlyPresentation
P3=TestLeaseRefs_ADeltaLeaseReturnsExactlyTheUnchargedTokens

fails=0
mut() { # mut <label> <python-regex pattern> <replacement> <test that must FAIL>...
  local label="$1" pat="$2" rep="$3" m ov out name missing=""
  shift 3
  m=$(mktemp -p "$W" mut.XXXXXX.go) || exit 2
  ov=$(mktemp -p "$W" overlay.XXXXXX.json) || exit 2
  python3 - billing.go "$m" "$pat" "$rep" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/billing.go" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run "$FOCUS" . 2>&1)
  for name in "$@"; do
    [[ "$out" == *"--- FAIL: $name "* ]] || missing="$missing $name"
  done
  if [ -z "$missing" ]; then
    echo "  convicted $label by $*"
  else
    echo "  NOT CONVICTED $label by$missing"; tail -15 <<<"$out"; fails=$((fails+1))
  fi
}
# Every pattern anchors on settlePayment's own body, so none can hit another function in billing.go.
F='(func \(w \*Wallet\) settlePayment\(plain \[\]Token, blind \[\]BlindToken, spent int\) \{\n)'
mut "M1 the plain HEAD returned instead of the tail" \
  'w\.Tokens = append\(w\.Tokens, plain\[plainSpent:\]\.\.\.\)' \
  'w.Tokens = append(w.Tokens, plain[:len(plain)-plainSpent]...)' "$P1" "$P3"
mut "M2 the blind HEAD returned instead of the tail" \
  'w\.BlindTokens = append\(w\.BlindTokens, blind\[blindSpent:\]\.\.\.\)' \
  'w.BlindTokens = append(w.BlindTokens, blind[:len(blind)-blindSpent]...)' "$P1" "$P2"
mut "M3 blind settled before plain" \
  '\tplainSpent := spent\n\tif plainSpent > len\(plain\) \{\n\t\tplainSpent = len\(plain\)\n\t\}\n\tblindSpent := spent - plainSpent\n\tif blindSpent > len\(blind\) \{\n\t\tblindSpent = len\(blind\)\n\t\}\n' \
  $'\tblindSpent := spent\n\tif blindSpent > len(blind) {\n\t\tblindSpent = len(blind)\n\t}\n\tplainSpent := spent - blindSpent\n\tif plainSpent > len(plain) {\n\t\tplainSpent = len(plain)\n\t}\n' \
  "$P1" "$P3"
mut "M4 the spent < 0 clamp removed" \
  "$F"'\tif spent < 0 \{\n\t\tspent = 0\n\t\}\n' \
  $'func (w *Wallet) settlePayment(plain []Token, blind []BlindToken, spent int) {\n' "$P1"
mut "M5 the blindSpent > len(blind) clamp removed" \
  '(\tblindSpent := spent - plainSpent\n)\tif blindSpent > len\(blind\) \{\n\t\tblindSpent = len\(blind\)\n\t\}\n' \
  $'\tblindSpent := spent - plainSpent\n' "$P1"
# M6 (review finding RF-001): the returned blind tokens keep their nonces but carry a changed expiry, so a
# comparison by nonce alone passes it. The gateway would refuse every such token at Verify.
mut "M6 the returned blind tokens' expiry changed" \
  'w\.BlindTokens = append\(w\.BlindTokens, blind\[blindSpent:\]\.\.\.\)' \
  $'for _, b := range blind[blindSpent:] {\n\t\traw, _ := base64.StdEncoding.DecodeString(b.Msg)\n\t\tb.Msg = base64.StdEncoding.EncodeToString([]byte(strings.Replace(string(raw), "|2000000000", "|1", 1)))\n\t\tw.BlindTokens = append(w.BlindTokens, b)\n\t}' \
  "$P1" "$P2" "$P3"
[ "$fails" -eq 0 ] && echo "== all 6 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
