#!/usr/bin/env bash
# test-worker-stop.sh [--mutate] -- runs worker_stop_test.go (NWP-20261120-01); --mutate re-runs it with each part of
# the odrestore give-up stop broken in turn (main.go, worker_stop.go, property_contexts), restoring every file on exit.
# Each mutant must be CONVICTED by the named test's `--- FAIL`; one that fails to apply, or fails to compile, counts as
# a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
STOP=worker_stop.go
CTX=../vendor-common/sepolicy/property_contexts
RUN=(go test -count=1 -run '^TestWorkerStop' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$MAIN" "$W/main.go.orig"
cp "$STOP" "$W/worker_stop.go.orig"
cp "$CTX" "$W/property_contexts.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; cp -f "$W/worker_stop.go.orig" "$STOP" 2>/dev/null; cp -f "$W/property_contexts.orig" "$CTX" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/main.go.orig" "$MAIN"; cp "$W/worker_stop.go.orig" "$STOP"; cp "$W/property_contexts.orig" "$CTX"; }
# conv <label> <expected failing test>: run the suite against the mutated tree, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $2"* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
mut() { # mut <label> <expected failing test> <file> <python-regex pattern> <replacement>
  python3 - "$3" "$4" "$5" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1" "$2"
}
mut "m1 the stop call removed" TestWorkerStopAbandonedOdrestoreFreesTheLane "$MAIN" \
  '(if stopOnGiveUp\(op\) \{\n\t+)stopAbandonedWorker\(lane, op\)' '\1_ = lane'
mut "m2 every op stopped" TestWorkerStopNotSentForOtherOps "$STOP" \
  'return op == "odrestore"' 'return op != ""'
mut "m3 no wait after the stop" TestWorkerStopWaitsForALateStop "$STOP" \
  'for i := 0; i < workerStopSamples; i\+\+ \{' 'for i := 0; i < 0; i++ {'
# m4 is convicted by the ignoring init's sample count and overshoot, never by go test's timeout: that fake reports
# stopped after workerStopSamples+5 samples, so the unbounded loop ends.
mut "m4 the sample bound removed" TestWorkerStopBoundedWhenInitIgnoresIt "$STOP" \
  'for i := 0; i < workerStopSamples; i\+\+ \{' 'for i := 0; i >= 0; i++ {'
mut "m5 the ctl.stop label line removed" TestWorkerStopPropertyLabelled "$CTX" \
  'ctl\.stop\$nowhere_roamd[ \t]+u:object_r:ctl_nowhere_roamd_prop:s0\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
