#!/usr/bin/env bash
# test-coldlock-pending.sh [--mutate] -- runs coldlock_pending_test.go + TestConcurrentSafeCmd (NWP-20261022-25); --mutate
# re-runs them against main.go with each guard of GET-COLDLOCK-PENDING broken in turn, restoring the file on exit. Each
# mutant must be CONVICTED (a `--- FAIL`); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestColdLockPending|TestConcurrentSafeCmd' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local mout mrc
  mout=$("${RUN[@]}" 2>&1); mrc=$?
  if [ $mrc -ne 0 ] && [[ "$mout" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1 (rc=$mrc, no --- FAIL)"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "M1 the bell check dropped" 'if !coldLockRunning \|\| coldLockBellAt != 0 \|\| coldLockRevoking' 'if !coldLockRunning || coldLockRevoking'
mut "M2 the uid not cleared at the end" 'coldLockRunning = false\n\tcoldLockUID = ""\n' 'coldLockRunning = false\n'
mut "M3 the logoff check dropped" ' \|\| logoffInFlight\(coldLockUID\)' ''
mut "M4 the verb left out of concurrentSafeCmd" '\t\t"GET-COLDLOCK-PENDING",\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
