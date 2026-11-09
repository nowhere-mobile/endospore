#!/usr/bin/env bash
# test-signout-renewal.sh [--mutate] -- runs logout_renew_test.go (NWP-20261112-14, Q088's device half): a landed
# sign-out renews the whole footprint before its wallet publish unless the footprint was already renewed in this
# epoch, and the periodic path keeps its own rule. --mutate re-runs it against a COPY of the package with each guard
# broken in turn; the tree is never touched. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to
# apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestSignOutRenewal' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res mrc
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
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
# both <pattern1> <repl1> <pattern2> <repl2>: two substitutions, each of which must apply exactly once.
both() { echo "(lambda a: None if a[1] != 1 else (lambda b: b[0] if b[1] == 1 else None)(re.subn($3, $4, a[0], count=1)))(re.subn($1, $2, s, count=1))"; }
mut "M1 the sign-out rule is renewalDue alone" billing.go \
  "$(one "r'(func signOutRenewalDue\(w \*Wallet, nowEpoch int64\) bool \{\n\treturn )w\.RenewedEpoch < nowEpoch \|\| renewalDue\(w, nowEpoch\)'" "lambda m: m.group(1) + 'renewalDue(w, nowEpoch)'")"
mut "M2a the same-epoch skip removed (wallet file)" billing.go \
  "$(one "r'(func signOutRenewalDue\(w \*Wallet, nowEpoch int64\) bool \{\n\treturn )w\.RenewedEpoch < nowEpoch \|\| renewalDue\(w, nowEpoch\)'" "lambda m: m.group(1) + 'true'")"
mut "M2b the same-epoch skip removed (no wallet file)" billing.go \
  "$(one "r'(func noWalletSignOutDue\(meterKey string, nowEpoch int64\) bool \{\n(?:.*\n)*?\treturn )sim\.RenewedEpoch < nowEpoch\n'" "lambda m: m.group(1) + 'sim.RenewedEpoch <= nowEpoch\n'")"
mut "M3 the renewal runs after logoutWalletStep" main.go \
  "$(one "r'(\t\tgoSafe\(\"logout-wallet\", func\(\) \{\n)(\t\t\tlogoutRenewStep[^\n]*\n)(\t\t\tlogoutWalletStep[^\n]*\n)'" "lambda m: m.group(1) + m.group(3) + m.group(2)")"
mut "M4 the GATEWAY_URL guard removed" logout_renew.go \
  "$(one "r'\tif gw == \"\" \{\n\t\treturn // managed-store billing not configured on this device\n\t\}\n'" "''")"
mut "M5 the periodic path takes the sign-out rule" billing.go \
  "$(both "r'(\t\treturn signOutRenewalDue\(w, nowEpoch\)\n\t\}\n\treturn )periodicRenewalDue\(w, nowEpoch\)'" "lambda m: m.group(1) + 'signOutRenewalDue(w, nowEpoch)'" \
          "r'(\t\treturn noWalletSignOutDue\(meterKey, nowEpoch\)\n\t\}\n\treturn )noWalletRenewalDue\(meterKey, nowEpoch\)'" "lambda m: m.group(1) + 'noWalletSignOutDue(meterKey, nowEpoch)'")"
mut "M6 the free latch read bypasses its lock" billing.go \
  "$(one "r'freeRenewedEpoch\(meterKey\) >= q\.CurrentEpoch'" "'freeRenewedThrough[meterKey] >= q.CurrentEpoch'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
