#!/usr/bin/env bash
# test-bound-budget.sh [--mutate] -- runs telephony_bound_budget_test.go (NWP-20261019-02); --mutate re-runs it against
# the budget code with each part of the change broken in turn, restoring the files on exit. Each mutant must be
# CONVICTED (a real --- FAIL; one that fails to apply or to compile counts as a failure).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
OWN=telephony_owner.go; INB=telephony_inbox.go; MAIN=main.go
RUN=(go test -count=1 -run 'TestBoundBudget_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "$OWN" "$INB" "$MAIN"; do cp "$f" "$f.orig"; done
trap 'for f in "$OWN" "$INB" "$MAIN"; do mv -f "$f.orig" "$f"; done' EXIT
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
  res=$("${RUN[@]}" 2>&1); rc=$?
  if [ $rc -ne 0 ] && grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1 (rc=$rc, no --- FAIL)"; fails=$((fails+1)); fi
  for f in "$OWN" "$INB" "$MAIN"; do cp "$f.orig" "$f"; done
}
mut "telStoreUsage counts .seal only" "$OWN" '\|\| strings\.HasSuffix\(n, "\.pend"\)' ''
mut "helper never strips" "$INB" 'it\.Kind == "mms" && telStoreUsage' 'false && telStoreUsage'
mut "helper strips every MMS" "$INB" 'telStoreUsage\(telInboxBase\)\+int64\(len\(blob\)\) > telBoundBudgetSoft' 'true'
mut "strip applied to every kind" "$INB" 'it\.Kind == "mms" && telStoreUsage' 'telStoreUsage'
mut "live mailbox row stripped too" "$MAIN" 'appendTelIngest\(lUID, tag, it\) == nil' 'appendTelIngest(lUID, tag, func() telItem { c := it; c.Parts = nil; c.Note = "too-large"; return c }()) == nil'
mut "soft line weighed against the owner base" "$INB" 'telStoreUsage\(telInboxBase\)\+int64\(len\(blob\)\) > telBoundBudgetSoft' 'telStoreUsage(ownerInboxBase)+int64(len(blob)) > telBoundBudgetSoft'
[ $fails -eq 0 ] || { echo "$fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
