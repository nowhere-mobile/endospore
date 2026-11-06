#!/usr/bin/env bash
# test-coldlock-wipe-wallet.sh [--mutate] -- runs the cold-lock-wipe wallet cases (coldlock_wipe_wallet_test.go;
# NWP-20261030-03); --mutate re-runs them against coldlock_evict.go with handleClaimColdLock's wallet removal broken
# in turn, restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or
# to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=coldlock_evict.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestColdLockWipeWallet_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$F.orig" "$F"
}
CALL='\tremoveWallet(walletPathFor(dest))\n'
NOTE='\tnoteCreditLostAtWipe(dest, uid, isLocalSession(dest))\n'
MARK='\tuid := strings.TrimSpace(u)\n\tif _, cl, _, _, _, _ := readColdLock(dest); cl =='
mut "W1 the removeWallet call deleted" \
  "s.replace('$CALL', '', 1) if s.count('$CALL') == 1 else None"
mut "W2 the removal moved before the credit-lost note" \
  "s.replace('$CALL', '', 1).replace('$NOTE', '$CALL$NOTE', 1) if s.count('$CALL') == 1 and s.count('$NOTE') == 1 else None"
mut "W3 the removal also runs on the GONE arm" \
  "s.replace('$MARK', '$CALL$MARK', 1) if s.count('$MARK') == 1 and s.count('$CALL') == 1 else None"
mut "W4 replaced by os.Remove (no generation bump)" \
  "s.replace('$CALL', '\tos.Remove(walletPathFor(dest))\n', 1) if s.count('$CALL') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
