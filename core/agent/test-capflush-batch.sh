#!/usr/bin/env bash
# test-capflush-batch.sh [--mutate] -- runs the TestCapFlushBatch tests in capflush_batch_test.go (NWP-20261112-08,
# Q090): capFlush's entitled lease goes in batches of leaseBatchRefs, the purchase on the first and judged on the
# whole flush, batch 0 settled and the wallet saved before the tokenless later batches, and a later batch that fails
# fails the flush (a 402 as a credit refusal), recording what landed for the hand-back. NWP-20261112-13: the free
# lease goes in the same batches, each with its own expire and release subsets; a 402 on any free batch sends the
# WHOLE flush down the entitled arm, any other refusal fails it, and the free batches that landed are recorded for the
# hand-back, alone or with the entitled batches that landed after them.
# --mutate re-runs them against main.go with each rule broken in turn, restoring the file on exit (the pristine copy
# lives in one scratch root, never beside the source). Each mutant must be CONVICTED by a real `--- FAIL`; one that
# fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
F=main.go
trap '[ -f "$W/$F.orig" ] && cp -f "$W/$F.orig" "$F"; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestCapFlushBatch' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <regex pattern> <repl, with \1-style group references>
  python3 - "$F" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/$F.orig" "$F"
}
mut "M1 later batches present the tokens" \
  'li, lc, le = gw\.leaseEntitledExpire\(profile, nil, nil, b, periods' 'li, lc, le = gw.leaseEntitledExpire(profile, plain, blind, b, periods'
mut "M2 planPurchase is fed batch 0's bytes" \
  'for _, sz := range refs \{(\n\t+incomingB \+= sz)' 'for _, sz := range leaseBatches(refs, leaseBatchRefs)[0] {\1'
mut "M3 a failed later batch is skipped instead of failing the flush" \
  'if rerr != nil \|\| rcode != http\.StatusOK \{' 'if rerr != nil {'
mut "M4 the 409 retry sends the whole map" \
  'info, pcode, err = gw\.leaseEntitledExpire\(profile, nil, nil, batches\[0\], periods, 0, "", prior, expireFor\(batches\[0\]\), releaseCommits\(sess\.dk, batches\[0\]\)\)' \
  'info, pcode, err = gw.leaseEntitledExpire(profile, nil, nil, refs, periods, 0, "", prior, expireFor(refs), releaseCommits(sess.dk, refs))'
mut "M5 the later batches' write caps are not merged" \
  'dst\.WriteCaps\[k\] = v' '_, _ = k, v'
mut "M6 the settlement and save run after the later batches" \
  '(\t+// Keep what the gateway didn.t charge\..*?saveOurWallet\(wpath, w, walletOurs && \(!scopeFlush \|\| scopeBought\), walletGen\)\n)(\t+// Q090: THE LATER BATCHES.*?\t+mergeLeaseInfo\(&info, rest\)\n)' '\2\1'
mut "M7 a later 402 is handled by fail() instead of creditRefused" \
  'panic\(creditRefused\(rest\.Reason\)\)' 'fail(rest.Reason)'
mut "M8 a partial landing is not recorded" \
  'capLeaseLanded = (&capLeaseRec\{profile: profile, prior: lp, refs: cp, periods: leasePeriods\}\n\t+\}\n\t+check\(rerr\))' '_ = \1'
mut "M9 the free attempt sends the whole map" \
  'freeBatches := leaseBatches\(refs, leaseBatchRefs\)' 'freeBatches := []map[string]int64{refs}'
mut "M10 a 402 on a later free batch is treated as success" \
  'rest, landed, code, err = capLeaseBatches\(freeBatches\[1:\], freeLease\)' 'rest, landed, _, err = capLeaseBatches(freeBatches[1:], freeLease)'
mut "M11 the entitled fallback leases only the batches not leased free" \
  '(\t+if code == http\.StatusOK \{\n\t+mergeLeaseInfo\(&info, rest\)\n)' \
  'if code == http.StatusPaymentRequired {\nfor k := range freeBatches[0] {\ndelete(refs, k)\n}\n}\n\1'
mut "M12 a partial free landing is not recorded" \
  'capLeaseLanded = (&capLeaseRec\{profile: profile, prior: lp, refs: freeLanded\})' '_ = \1'
mut "M13 the entitled record drops the free landing" \
  '\t+for k, v := range freeLanded \{[^\n]*\n\t+cp\[k\] = v\n\t+\}\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
