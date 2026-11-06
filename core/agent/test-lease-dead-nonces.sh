#!/usr/bin/env bash
# test-lease-dead-nonces.sh [--mutate] -- runs lease_dead_nonces_test.go (NWP-20261020-03); --mutate re-runs it against
# billing.go / main.go with each guard broken in turn, restoring the files on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
BILL=billing.go; MAIN=main.go
RUN=(go test -count=1 -run 'TestLeaseDeadNonces_|TestCapFlush409|TestLeaseRefs409' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
grep -E '^(--- |ok|FAIL|PASS)' <<<"$out" | tail -25
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

for f in "$BILL" "$MAIN"; do cp "$f" "$f.orig"; done
trap 'for f in "$BILL" "$MAIN"; do mv -f "$f.orig" "$f"; done' EXIT
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  for f in "$BILL" "$MAIN"; do cp "$f.orig" "$f"; done
}
SETTLE='w\.settlePayment\(keepPlain, keepBlind, 0\)'
mut "M1 every presented token dropped (capFlush)" "$MAIN" "$SETTLE" 'w.settlePayment(nil, nil, 0)'
mut "M2 every presented token dropped (leaseRefs)" "$BILL" "$SETTLE" 'w.settlePayment(nil, nil, 0)'
mut "M3 filter applied after the settle (capFlush)" "$MAIN" "$SETTLE" 'w.settlePayment(plain, blind, 0)'
mut "M4 filter applied after the settle (leaseRefs)" "$BILL" "$SETTLE" 'w.settlePayment(plain, blind, 0)'
mut "M5 a name not presented removes a wallet token (capFlush)" "$MAIN" "$SETTLE" 'w.Tokens, w.BlindTokens, _ = dropNamedSpent(w.Tokens, w.BlindTokens, info.SpentNonces)
				w.settlePayment(keepPlain, keepBlind, 0)'
mut "M6 a name not presented removes a wallet token (leaseRefs)" "$BILL" "$SETTLE" 'w.Tokens, w.BlindTokens, _ = dropNamedSpent(w.Tokens, w.BlindTokens, info.SpentNonces)
			w.settlePayment(keepPlain, keepBlind, 0)'
mut "M7 bound removed" "$BILL" 'func leaseConflictRead\(presented int\) int \{ return [^\n]*\}' 'func leaseConflictRead(presented int) int { return 1 << 30 }'
mut "M8 truncation check removed" "$BILL" 'if len\(body\) > conflictRead \{' 'if false {'
mut "M9 Reason computed over the longer read" "$BILL" 'gatewayReason\(head\), body, nil' 'gatewayReason(body), body, nil'
mut "M10 alphabet test removed" "$BILL" 'if !\(c >= ' 'if false && !(c >= '
mut "M11 length cap removed" "$BILL" 'len\(s\) > 64' 'false'
mut "M12 blind nonce read from field 1" "$BILL" 'set\[parts\[1\]\]' 'set[parts[0]]'
mut "M13 SpentNonces never set" "$BILL" 'out\.SpentNonces = spentNamed\(conflict\)' '_ = conflict'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
