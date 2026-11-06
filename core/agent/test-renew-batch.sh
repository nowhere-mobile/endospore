#!/usr/bin/env bash
# test-renew-batch.sh [--mutate] -- runs the TestRenewBatch tests in renew_batch_test.go (NWP-20261109-08, Q090):
# payRent renews in batches of leaseBatchRefs, the purchase on the first and judged on the whole footprint, later
# batches tokenless and carrying `prior`, and a short renewal records the spend but not the renewal stamp.
# --mutate re-runs them against billing.go with each rule broken in turn, restoring the file on exit (the pristine
# copy lives in one scratch root, never beside the source). Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
F=billing.go
trap '[ -f "$W/$F.orig" ] && cp -f "$W/$F.orig" "$F"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestRenewBatch' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <regex pattern> <repl>
  python3 - "$F" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
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
mut "M1 later batches present the tokens too" 'g\.leaseEntitled\(profile, nil, nil, b, periods' 'g.leaseEntitled(profile, plain, blind, b, periods'
mut "M2 planPurchase is fed batch 0's bytes" 'for _, sz := range refs \{\n\t\t\tincoming \+= sz' 'for _, sz := range batches[0] {
			incoming += sz'
mut "M3 a short renewal is recorded as full" 'full := info\.BatchesShort == 0' 'full := true || info.BatchesShort == 0'
mut "M4 the loop stops at the first failed later batch" 'info\.BatchesShort\+\+\n\t\t\t\tcontinue' 'info.BatchesShort++
				break'
mut "M5 the retag record is dropped on a short paid renewal" 'if full \{\n\t\tdropBillRetag\(base, name, pass, dk, prior\)\n\t\}\n\treturn info, true, err' 'if true {
		dropBillRetag(base, name, pass, dk, prior)
	}
	return info, true, err'
mut "M6 the free latch is set on a short free renewal" 'if finfo\.BatchesShort == 0 \{' 'if true {'
mut "M7 later batches drop prior" 'g\.leaseEntitled\(profile, nil, nil, b, periods, 0, "", prior\)' 'g.leaseEntitled(profile, nil, nil, b, periods, 0, "", nil)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
