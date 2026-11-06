#!/usr/bin/env bash
# test-store-giveup.sh [--mutate] -- runs store_giveup_test.go (NWP-20261028-02): armed (a sign-in's restore processes,
# a DELETE), retryStoreWithin starts no attempt once the store has not answered for 15 s; unarmed nothing changes.
# --mutate re-runs the focused tests against pristine copies of main.go, store_giveup.go and nowhere_roamd.sh with each
# rule broken in turn, restoring them on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to
# apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
ROAMD=../vendor-common/bin/nowhere_roamd.sh
FILES=(main.go store_giveup.go "$ROAMD")
RUN=(go test -count=1 -run 'StoreGiveUp|RetryStore|CapGetFitsTheStallBudget|DeleteUnreachable|ConfFlags' .)
W=$(mktemp -d) || exit 2
restore() {
  local f
  for f in "${FILES[@]}"; do
    [ -f "$W/$(basename "$f").orig" ] && cp -f "$W/$(basename "$f").orig" "$f"
  done
  return 0
}
trap 'restore; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$(basename "$f").orig"; done
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local res
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else
    if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- did not compile"; else echo "  SURVIVED  $1"; fi
    fails=$((fails+1))
  fi
  restore
}
mut "B1 a success never clears the outage" store_giveup.go 'storeGiveUp\.failingSince = time\.Time\{\} // the store answered' '_ = 0 // the store answered'
mut "B2 the window measured from failingSince alone" store_giveup.go '\.Sub\(laterOf\(storeGiveUp\.failingSince, storeGiveUp\.armedAt\)\)' '.Sub(storeGiveUp.failingSince)'
mut "B3 storeGivenUp ignores armed" store_giveup.go 'storeGiveUp\.armed > 0 && ' ''
mut "B4 errStoreGaveUp does not wrap errStoreUnreachable" store_giveup.go 'func \(storeGaveUpErr\) Unwrap\(\) error \{ return errStoreUnreachable \}' 'func (storeGaveUpErr) Unwrap() error { return nil }'
mut "B5 the pre-attempt check removed" main.go '\t\tif storeGivenUp\(\) \{\n\t\t\tlogStoreGiveUpOnce\(what\)\n\t\t\treturn errStoreGaveUp\n\t\t\}\n' ''
mut "B6 errStorePermanent counted as a failure" store_giveup.go 'if err == nil \|\| errors\.Is\(err, errStorePermanent\) \{\n\t\tstoreGiveUp' 'if err == nil || errors.Is(err, nil) {\n\t\tstoreGiveUp'
mut "B8 a late failure backdates the outage past a response" store_giveup.go 'laterOf\(started, storeGiveUp\.answeredAt\)' 'started'
mut "B7 the roamd export unguarded" "$ROAMD" '\[ "\$op" = "in" \] && export NOWHERE_STORE_GIVEUP=1' 'export NOWHERE_STORE_GIVEUP=1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
