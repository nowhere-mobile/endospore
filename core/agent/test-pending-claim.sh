#!/usr/bin/env bash
# test-pending-claim.sh [--mutate] -- runs pending_claim_test.go (NWP-20261125-05, h53 #6 slice 1): the wallet carries
# pending claim codes (Wallet.PendingClaims), sealed with it; a power-off before the drain then a sign-in on another
# phone drains it; two phones drain it once; a code this session cleared is never brought back from a stored copy, and
# the seen-set keys a code by its hash, never the code; drainPendingClaims clears an entry only after a drainClaim call
# answers (0, nil), and keeps it on an error, a busy or unavailable wallet lock or a partial drain; mergeLateRestore
# keeps both sides' codes. --mutate re-runs the tests with each rule broken in turn and restores the files on exit. A mutant is
# CONVICTED only by a failing test (`--- FAIL`); one that does not apply, or that breaks the build, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(billing.go pending_claim.go wallet_restore.go wallet_seen.go)
restore() {
  local f
  for f in "${FILES[@]}"; do
    if [ -f "$W/$f.orig" ]; then cp "$W/$f.orig" "$f"; fi
  done
  rm -rf "$W"
}
trap restore EXIT
RUN=(go test -count=1 -run 'TestPendingClaim' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  cp "$W/$2.orig" "$2"
}
mut "a walletForPublish ignores seen for the pending codes" billing.go \
  'pendingClaimSeenKey\(c\); !have\[k\] && !seen\[k\]' 'pendingClaimSeenKey(c); !have[k]'
mut "b the entry is cleared on an error" pending_claim.go \
  '(errs = append\(errs, derr\)[^\n]*\n)' '\1\t\t\t\tcleared[code] = true\n'
mut "c mergeLateRestore drops the local list" wallet_restore.go \
  'codes = append\(codes, local\.PendingClaims\.\.\.\)' '_ = local'
mut "d the seen key stores the raw code" wallet_seen.go \
  'return "c:" \+ hex\.EncodeToString\(sum\[:\]\)' '_ = sum\n\treturn "c:" + code'
mut "e the entry is cleared as soon as tokens > 0, without the proving (0, nil)" pending_claim.go \
  'if got == 0 \{(\s*cleared\[code\] = true)' 'if got > 0 {\1'
mut "f the entry is cleared on any nil error, tokens or none" pending_claim.go \
  'if got == 0 \{(\s*cleared\[code\] = true)' 'if true {\1'
mut "g one drainClaim call per code: the proving 402 never asked for" pending_claim.go \
  'const maxPendingClaimCalls = 3' 'const maxPendingClaimCalls = 1'
mut "h a busy wallet lock at the clear is ignored" pending_claim.go \
  'switch state \{' 'if state == walletLockBusy {\n\t\tstate = walletLocked\n\t}\n\tswitch state {'
mut "i an unavailable wallet lock at the clear saves unlocked" pending_claim.go \
  'switch state \{' 'if state == walletLockUnavailable {\n\t\tstate = walletLocked\n\t}\n\tswitch state {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
