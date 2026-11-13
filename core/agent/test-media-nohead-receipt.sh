#!/usr/bin/env bash
# test-media-nohead-receipt.sh [--mutate] -- a #media session whose sign-in proved there was no head passes the
# no-receipt gate when the carry folds the stored head in, and is refused without the carry (NWP-20261201-11). Plain:
# the no-receipt, no-head and early-guard tests. --mutate applies each mutant in place (pristine copies live in one temp
# root, restored after every mutant and on exit) and runs the no-receipt tests; each must be CONVICTED by the named
# `--- FAIL`. A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go restore_receipt.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestNoHeadReceipt|TestMediaCarryNoHead|TestSealEarlyGuard' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want
  shift 4
  python3 - "$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -run 'TestNoHeadReceipt' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
P=TestNoHeadReceipt_
A=${P}TheSecondPhoneSealsWhenTheCarryFoldsTheHeadIn
B=${P}WithoutTheCarryTheSecondPhoneIsStillRefused
C=${P}ARealRosterWithoutAReceiptIsRefusedBeforeTheWalk
D=${P}CarryOffRefusesBeforeTheWalk
HELP='return mediaEssentialCarryOn(profile) && loginRosterHead(ref) == loginRosterNone'
mut "R1 the helper returns false" restore_receipt.go "$HELP" 'return false' "$A"
# `false` alone would leave noReceiptDeferred assigned and never read, which Go refuses to compile.
mut "R2 the post-walk refusal is removed" main.go 'if noReceiptDeferred && !mediaCarryRan {' 'if noReceiptDeferred && false {' "$B"
mut "R3 the sentinel test accepts any roster" restore_receipt.go "$HELP" 'return mediaEssentialCarryOn(profile) && loginRosterHead(ref) != ""' "$C"
mut "R4 the helper ignores the carry switch" restore_receipt.go "$HELP" 'return loginRosterHead(ref) == loginRosterNone' "$D"
mut "R5 the post-walk check ignores the carry" main.go 'if noReceiptDeferred && !mediaCarryRan {' 'if noReceiptDeferred {' "$A"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
