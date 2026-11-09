#!/usr/bin/env bash
# test-coldlock-armfail.sh [--mutate] -- runs coldlock_armfail_test.go (NWP-20261031-06) and coldlock_late_rekey_test.go
# (NWP-20261126-01, NWP-20261128-06); --mutate re-runs them against main.go with each guard of the arm-fail hand-off,
# the never-moved set, the late-rekey read and the bound's no-keep sign-out broken in turn, restoring the file on exit. Each mutant must be CONVICTED (a real
# `--- FAIL`); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestColdLockArmFail|TestColdLockLateRekey' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

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
mut "A1 the branch deleted" 'if !coldLockArmLanded\(needKey, armOut, fwdRekey\) \{' 'if false {'
mut "A2 OK NOTARMED treated as landed" 'return armOut == "OK ARMED" \|\| armOut == "OK"' 'return armOut == "OK ARMED" || armOut == "OK" || armOut == "OK NOTARMED"'
mut "A3 the throwaway also signs out" 'if localOnlySession\(dest\) \{\n(\t\t\tfmt.Fprintf\(os.Stderr, "\[logind\] cold-lock arm failure[^\n]*\n)\t\t\treturn true\n\t\t\}\n' 'if localOnlySession(dest) {\n\1\t\t\tgoSafe("coldlock-armfail-signout", func() { coldLockSignOut(dest) })\n\t\t\treturn true\n\t\t}\n'
mut "A4 queueIdleRearm dropped" '\t\tqueueIdleRearm\(uid\) // after the unlock[^\n]*\n' ''
mut "A5 the default sign-out without sessionMu" 'var coldLockSignOut = func\(dest string\) \{\n\tsessionMu.Lock\(\)\n\tdefer sessionMu.Unlock\(\)\n' 'var coldLockSignOut = func(dest string) {\n'
mut "A6 the branch placed after the wait" '(\tif !coldLockArmLanded\(needKey, armOut, fwdRekey\) \{.*?\n\t\treturn true\n\t\}\n)(.*?\tif held \{\n\t\tsetRWHolder\("coldlock"\)\n\t\})' '\2\n\1'
mut "A7 ERR-WORKER-BUSY dropped from the never-moved set" '"ERR-REQ", workerBusy, "ERR-UID":' '"ERR-REQ", "ERR-UID":'
mut "A8 ERR-UID dropped from the never-moved set" ', workerBusy, "ERR-UID":' ', workerBusy:'
mut "A9 the late-reply read skipped" 'if late := coldLockAwaitLateRekey\(dest\); late != ""' 'if late := ""; late != ""'
mut "A10 the record not re-checked under the slot" '(\t// roamcred.res may now hold that op.s reply.\n)\tif laneAbandonedOp\(laneCred\) != "rekey" \{\n\t\treturn ""\n\t\}\n' '\1'
mut "A11 the record cleared without a reply" '\tif !ok \{\n\t\treturn "" // the record stays' '\tclearLaneAbandoned(laneCred)\n\tif !ok {\n\t\treturn "" // the record stays'
mut "A12 the bound commits as before" '(fwdRekey = late\n\t\t\t\}) else \{' '\1 else if false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
