#!/usr/bin/env bash
# test-rearm-inbox-tempdir.sh [--mutate] -- runs goroutine_wait_test.go and the rearm-inbox tests it protects
# (NWP-20261024-13). --mutate re-runs the self-tests against go_safe.go / goroutine_wait_test.go with each part of the
# tracker broken in turn, restoring both on exit. Each mutant must be CONVICTED by the named test's `--- FAIL`; one that
# fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
SAFE=go_safe.go
WAIT=goroutine_wait_test.go
trap 'for f in "$SAFE" "$WAIT"; do [ -f "$f.orig" ] && mv -f "$f.orig" "$f"; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestGoroutineWait|TestLogoffRearmInbox_' -v .)
SELF=(go test -count=1 -run 'TestGoroutineWait' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SAFE" "$SAFE.orig"; cp "$WAIT" "$WAIT.orig"
fails=0
# mut <label> <file> <python-regex> <replacement> <convicting test>...
mut() {
  local label="$1" file="$2" pat="$3" rep="$4" res want
  shift 4
  python3 - "$file" "$pat" "$rep" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(GOMAXPROCS=1 "${SELF[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  cp "$SAFE.orig" "$SAFE"; cp "$WAIT.orig" "$WAIT"
}
mut "W1 tr.wait returns at once" "$WAIT" '(func \(tr \*goSafeTracker\) wait\(t \*testing\.T, limit time\.Duration\) \{\n\tt\.Helper\(\)\n)' '\1\treturn\n' TestGoroutineWait_GuardSeesALateWriter/wait=true
mut "W2 defer done() dropped from goSafe" "$SAFE" 'fn = func\(\) \{ defer done\(\); runSafe\(job, inner\) \}' 'fn = func() { runSafe(job, inner) }' TestGoroutineWait_TracksAtStart TestGoroutineWait_PanickingJobEnds
mut "W3 dirCameBack always nil" "$WAIT" '(func dirCameBack\(root string, settle time\.Duration\) \[\]string \{\n)' '\1\treturn nil\n' TestGoroutineWait_GuardSeesALateWriter/wait=false
mut "W4 hook moved into runSafe" "$SAFE" '\tif track := goSafeTrack\.Load\(\); track != nil \{.*?\n\t\}\n\tgo runSafe\(job, fn\)\n(.*?func runSafe\(job string, fn func\(\)\) \(returned bool\) \{\n)' '\tgo runSafe(job, fn)\n\1\tif track := goSafeTrack.Load(); track != nil {\n\t\tif done := (*track)(job); done != nil {\n\t\t\tinner := fn\n\t\t\tfn = func() { defer done(); inner() }\n\t\t}\n\t}\n' TestGoroutineWait_HookBeforeGoStatement TestGoroutineWait_TracksAtStart
mut "W5 joinSignOuts returns at once (RF-001, as on main)" "$WAIT" '(func \(tr \*goSafeTracker\) joinSignOuts\(t \*testing\.T, limit time\.Duration\) \{\n\tt\.Helper\(\)\n)' '\1\treturn\n' TestGoroutineWait_TheStandInJoinsARunningLogoff
mut "W6 a logoff in its reap wait is not parked" "$WAIT" 'tr\.parked\[id\] = true' '_ = id' TestGoroutineWait_TheJoinDoesNotWaitOutTheReap
mut "W7 rwLaneFree does not wait" "$WAIT" '(func rwLaneFree\(t \*testing\.T\) \{\n\tt\.Helper\(\)\n)' '\1\treturn\n' TestGoroutineWait_ASignOutTestWaitsForAHeldLane
mut "W8 an ended logoff keeps its park (RF-001)" "$WAIT" '\t+delete\(tr\.parked, id\)\n' '\t\t\t\t_ = id\n' TestGoroutineWait_AnEndedParkDoesNotCoverALiveLogoff
mut "W9 any job's reap wait parks" "$WAIT" ' && inHandleLogout\(\)' '' TestGoroutineWait_AnotherJobsReapWaitParksNoLogoff
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
