#!/usr/bin/env bash
# test-signout-strict-read.sh [--mutate] -- runs signout_strict_read_test.go (NWP-20261201-22, h60 #16): a landed
# sign-out reads the stored wallet strictly before its switch; unreadable, it publishes no #wallet, keeps the file and
# records the notice before the switch. --mutate re-runs it against a COPY of the package with each guard broken in
# turn; the tree is never touched. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestSignOutStrictRead_' -v .)

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
READ="r'(\t\t\treadable := endStoredWalletRead\([^\n]*\n)'"
mut "M1 the read's result forced readable (convicted by UnreadableKeepsTheStoredWallet)" main.go \
  "$(one "$READ" "lambda m: m.group(1) + '\t\t\treadable = true\n'")"
mut "M2 the logoffCreditLost assignment removed (convicted by UnreadableKeepsTheStoredWallet)" main.go \
  "$(one "r'\t\t\t\t\tlogoffCreditLost = true\n'" "''")"
mut "M3 sealLogoutWalletAndDrop's note check removed (convicted by UnreadableKeepsTheStoredWallet)" logout_wallet.go \
  "$(one "r'\tif logoutWalletUnreadable\(gen\) \{\n\t\treturn false, errLogoutWalletUnreadable\n\t\}\n'" "''")"
mut "M4 one try only (convicted by HelperTriesTwiceInOneBound)" signout_strict_read.go \
  "$(one "r'try < 2'" "'try < 1'")"
mut "M5 the bound removed (convicted by HelperTriesTwiceInOneBound)" signout_strict_read.go \
  "$(one "r'\tselect \{\n\tcase ok := <-res:\n\t\treturn ok\n\tcase <-time\.After\(endStoredWalletReadWait\):\n\t\treturn false\n\t\}\n'" "'\treturn <-res\n'")"
mut "M6 the read moved after the closure (convicted by BeforeTheSwitch)" main.go \
  "$(one "r'(?s)(\t\t// NWP-20261201-22 \(h60 #16.*?\n\t\t\}\n)(\t\t// NWP-20261014-66: the verdict.*?\n\t\t\}\(\)\n)'" "lambda m: m.group(2) + m.group(1)")"
mut "M7 the clear removed (convicted by AReadableReadClearsTheNote)" main.go \
  "$(one "r' else \{\n\t\t\t\tsetLogoutWalletUnreadable\(lgen, false\)\n\t\t\t\}'" "''")"
mut "M8 the read's result forced unreadable (convicted by ReadablePublishes and AReadableReadClearsTheNote)" main.go \
  "$(one "$READ" "lambda m: m.group(1) + '\t\t\treadable = false\n'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
