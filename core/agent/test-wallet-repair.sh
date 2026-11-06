#!/usr/bin/env bash
# test-wallet-repair.sh [--mutate] -- runs the REPAIR-WALLET cases (wallet_repair_test.go; NWP-20261103-03);
# --mutate re-runs them against wallet_restore.go with the repair broken in turn, restoring the file
# on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=wallet_restore.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestWalletRepair_|TestStrictWallet_' -v .)

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
mut "W1 a 403 counted as damage" \
  "s.replace('return errors.Is(err, errWalletBlobDamaged) ||', 'return strings.Contains(err.Error(), \"status 403\") || errors.Is(err, errWalletBlobDamaged) ||', 1) if s.count('return errors.Is(err, errWalletBlobDamaged) ||') == 1 else None"
mut "W2 CONFIRM skips the second read" \
  "s.replace('\tv := repairWalletVerdict(wp, gen, name, pass, se)\n', '\tv := \"DAMAGED\"\n\tif !confirm {\n\t\tv = repairWalletVerdict(wp, gen, name, pass, se)\n\t}\n', 1) if s.count('\tv := repairWalletVerdict(wp, gen, name, pass, se)\n') == 1 else None"
mut "W3 the generation recheck under the lock removed" \
  "s.replace('\tif !walletAtGeneration(wp, gen) {\n\t\treturn \"REFUSED GEN\"\n\t}\n', '', 1) if s.count('return \"REFUSED GEN\"') == 1 else None"
mut "W4 unparsable not counted as damage" \
  "s.replace(' ||\n\t\terrors.Is(err, errWalletUnparsable)', '', 1) if s.count(' ||\n\t\terrors.Is(err, errWalletUnparsable)') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
