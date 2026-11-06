#!/usr/bin/env bash
# test-reboot-fallback-pending.sh [--mutate] -- runs reboot_fallback_pending_test.go (NWP-20261017-07, and NWP-20261107-06's delete-removal phase); --mutate re-runs
# it against main.go / telephony_count.go with each guard broken in turn, restoring the files on exit. Each mutant must
# be CONVICTED (a --- FAIL); one that fails to apply, or fails to compile, counts as a failure. H1-H4
# (NWP-20261112-19) break reapWaitHook, the named-wait hook the tests consume the queue from. L1 (NWP-20261115-09), in
# plain mode too, re-runs the cases with a stall of two windows at every wait: they assert their waits and lower bounds
# only, so load must not fail them. Every temp and backup lives under one root, "$W"; the EXIT trap restores every file
# the suite changed and then removes it.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go; CNT=telephony_count.go; TST=reboot_fallback_pending_test.go
W=$(mktemp -d) || exit 2
restore() { # copies back every file the suite changed
  local f
  for f in "$MAIN" "$CNT" "$TST"; do
    if [ -f "$W/$f.orig" ] && ! cmp -s "$W/$f.orig" "$f"; then cp -f "$W/$f.orig" "$f"; fi
  done
}
trap 'restore; rm -rf "$W"' EXIT
mkdir "$W/tmp" || exit 2
export TMPDIR="$W/tmp" GOTMPDIR="$W/tmp"
cp "$MAIN" "$W/$MAIN.orig" && cp "$CNT" "$W/$CNT.orig" && cp "$TST" "$W/$TST.orig" || exit 2
RUN=(go test -count=1 -run 'TestRebootFallback_|TestTelPendingCount' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1

# L1: a stalled CPU at every wait. One throttled CPU-quota period can delay a woken sleeper by up to 100 ms; L1 stalls
# two windows (80 ms) at each wait, so a case that bounds wall time from above fails and one that asserts its waits
# does not.
python3 - "$TST" <<'PY' || { echo "L1 load leg: FAIL (the stall did not apply exactly once)"; exit 1; }
import sys
p=sys.argv[1]; a='reapWaitHook = func(phase string) {'
s=open(p).read()
if s.count(a)!=1: sys.exit(1)
open(p,'w').write(s.replace(a, a+'\n\t\ttime.Sleep(2 * rfpWait) // L1: a stalled CPU at every wait', 1))
PY
lout=$("${RUN[@]}" 2>&1); lrc=$?
cp -f "$W/$TST.orig" "$TST"
if [ "$lrc" -eq 0 ] && [[ "$lout" != *"--- FAIL"* ]]; then
  echo "L1 load leg: PASS"
else
  printf '%s\n' "$lout"; echo "L1 load leg: FAIL"; exit 1
fi
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python regex> <replacement>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1)
  if [[ "$mout" == *"--- FAIL"* ]]; then echo "  convicted $1"; else echo "  SURVIVED  $1 (no --- FAIL)"; echo "$mout" | head -5; fails=$((fails+1)); fi
  cp "$W/$MAIN.orig" "$MAIN"; cp "$W/$CNT.orig" "$CNT"
}
mut "M1 phase 1 re-queue removed" "$MAIN" 'if queueStuck\(&pendingSwitchUID, uid\) \{\n\t\trequeueForPending\("switch", reapSwitchWait\)\n\t\}\n\tpendingReapMu\.Lock\(\)\n\tswitchStuck' 'pendingReapMu.Lock()\n\tswitchStuck'
mut "M2 phase 2 re-queue removed" "$MAIN" 'if queueStuck\(&pendingReapUID, uid\) \{\n\t\trequeueForPending\("remove", reapRemoveWait\)\n\t\}\n' ''
mut "M3 delete 8s re-queue removed" "$MAIN" 'func deleteReapFallback\(uid string\) \{\n\treapWait\("switch", reapSwitchWait\)\n\tif queueStuck\(&pendingSwitchUID, uid\) \{\n\t\trequeueForPending\("switch", reapSwitchWait\)\n\t\}\n' 'func deleteReapFallback(uid string) {\n\treapWait("switch", reapSwitchWait)\n'
mut "M4 pending check inverted" "$CNT" 'return strconv\.Itoa\(n\), n > 0' 'return strconv.Itoa(n), n == 0'
mut "M5 count error treated as zero" "$CNT" 'return "an unknown number of", true' 'return "0", false'
mut "M6 no-uid hold unbounded" "$MAIN" 'waited < deleteNoUidHoldCap; waited' 'true; waited'
mut "M7 no-uid hold removed" "$MAIN" 'reapWait\("nouid-hold", deleteNoUidHoldStep\)\n' ''
mut "M8 cost line dropped from rebootNow" "$MAIN" 'if words, pending := pendingTelWords\(\); pending \{\n\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] reboot fallback' 'if words, pending := pendingTelWords(); pending && false {\n\t\tfmt.Fprintf(os.Stderr, "[logind] reboot fallback'
mut "M9 delete phase 2 removed" "$MAIN" '(func deleteReapFallback\(uid string\) \{(?:(?!\nfunc ).)*?\n\t\treturn\n\t\}\n)(?:(?!\nfunc ).)*?\n\}\n' '\1}\n'
mut "M10 delete remove re-queue removed" "$MAIN" '(func deleteReapFallback\(uid string\) \{(?:(?!\nfunc ).)*?)\tif queueStuck\(&pendingReapUID, uid\) \{\n\t\trequeueForPending\("remove", reapRemoveWait\)\n\t\}\n' '\1'
mut "M11 delete phase 2 checks the switch slot" "$MAIN" 'removeStuck := pendingReapUID == uid' 'removeStuck := pendingSwitchUID == uid'
mut "H1 requeueForPending's hook removed" "$MAIN" 'reapWait\(phase\+"-requeue", wait\)' 'time.Sleep(wait)'
mut "H2 reapOrReboot's switch-window hook removed" "$MAIN" '(func reapOrReboot\(uid string\) \{(?:(?!\nfunc ).)*?)reapWait\("switch", reapSwitchWait\)' '\1time.Sleep(reapSwitchWait)'
mut "H3 deleteReapFallback's remove-window hook removed" "$MAIN" '(func deleteReapFallback\(uid string\) \{(?:(?!\nfunc ).)*?)reapWait\("remove", reapRemoveWait\)' '\1time.Sleep(reapRemoveWait)'
mut "H4 requeueForPending passes the bare phase" "$MAIN" 'reapWait\(phase\+"-requeue", wait\)' 'reapWait(phase, wait)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
