#!/usr/bin/env bash
# test-billing-latch-forget.sh [--mutate] -- runs the billing-latch cases (billing_latch_forget_test.go; NWP-20261201-37,
# h60 #18): the login daemon forgets its two billing latches at every session end, after the sign-out renewal. --mutate
# re-runs them against a COPY of the package with each part broken in turn; the tree is never touched. Each mutant must
# be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestBillingLatchForget' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - "$file" "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
# B1: _ForgetSessionKeysEmptiesBoth, _ALandedSignOutForgetsAfterItsRenewal and _TheHelperTakesBothLocks convict it.
mut "B1 the forgetBillingLatches call removed" main.go \
  "$(one "r'\tforgetBillingLatches\(\)[^\n]*\n'" "''")"
# B2: _ForgetSessionKeysEmptiesBoth and _ALandedSignOutForgetsAfterItsRenewal convict it.
mut "B2 the freeRenewedThrough reset removed" billing.go \
  "$(one "r'(func forgetBillingLatches\(\) \{\n\tfreeRenewedMu\.Lock\(\)\n)\tfreeRenewedThrough = map\[string\]int64\{\}\n'" "lambda m: m.group(1)")"
# B3: _ForgetSessionKeysEmptiesBoth and _ALandedSignOutForgetsAfterItsRenewal convict it.
mut "B3 the noWalletRenewed reset removed" billing.go \
  "$(one "r'(func forgetBillingLatches[\s\S]*?noWalletRenewedMu\.Lock\(\)\n)\tnoWalletRenewed = map\[string\]\*Wallet\{\}\n'" "lambda m: m.group(1)")"
# B4: _ALandedSignOutForgetsAfterItsRenewal convicts it: the renewal latches again after the forget.
mut "B4 the logout-wallet forget moved above the renewal" main.go \
  "$(one "r'(\t\tgoSafe\(\"logout-wallet\", func\(\) \{\n)(\t\t\tlogoutRenewStep[^\n]*\n\t\t\tlogoutWalletStep[^\n]*\n)(\t\t\tforgetSessionKeys[^\n]*\n)'" "lambda m: m.group(1) + m.group(3) + m.group(2)")"
# B5: _TheHelperTakesBothLocks convicts it.
mut "B5 freeRenewedMu removed from the helper" billing.go \
  "$(one "r'(func forgetBillingLatches\(\) \{\n)\tfreeRenewedMu\.Lock\(\)\n(\tfreeRenewedThrough = map\[string\]int64\{\}\n)\tfreeRenewedMu\.Unlock\(\)\n'" "lambda m: m.group(1) + m.group(2)")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
