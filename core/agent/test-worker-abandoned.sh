#!/usr/bin/env bash
# test-worker-abandoned.sh [--mutate] -- runs worker_abandoned_test.go (NWP-20261022-02); --mutate re-runs it against
# main.go with each part of runWorkerHeld's abandoned-lane guard broken in turn, restoring the file on exit. Each mutant
# must be CONVICTED by the named test's `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run '^TestAbandoned' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
# conv <label> <expected failing test>: run the suite against the mutated main.go, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $2"* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$W/main.go.orig" "$MAIN"; }
mut() { # mut <label> <expected failing test> <python-regex pattern> <replacement>
  python3 - "$MAIN" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1" "$2"
}
mut "M1 the record not set on the stall exit" TestAbandonedOpOnTheLaneAnswersBusyWhileItRuns \
  '(if idle >= stallTicks \{\n\t+)return timedOut\(\)' '\1return "ERR-TIMEOUT"'
# M2 anchors on runWorkerHeld's own switch: coldLockWaitAbandoned (NWP-20261109-04) has the same case line on laneRW.
mut "M2 the running check removed" TestAbandonedOpOnTheLaneAnswersBusyWhileItRuns \
  '(switch workerState\(lane\.svc\) \{\n\t+)case "running", "stopping", "restarting":' '\1case "never":'
# M3 moves the whole guard to after the request is published.
python3 - "$MAIN" <<'PY' || inert "M3"
import sys
p=sys.argv[1]
s=open(p).read()
a=s.index('\tif abandoned := laneAbandonedOp(lane); abandoned != "" {')
b=s.index('\tos.Remove(res)\n', a)
blk=s[a:b]
s=s[:a]+s[b:]
anchor='\t\treturn "ERR-REQ"\n\t}\n'
i=s.index(anchor, a)+len(anchor)
open(p,'w').write(s[:i]+blk+s[i:])
PY
conv "M3 the check placed after the request is written" TestAbandonedOpOnTheLaneAnswersBusyWhileItRuns
mut "M4 the record cleared on the busy answer" TestAbandonedOpOnTheLaneAnswersBusyWhileItRuns \
  '(\t+)(return workerBusy\n\t\t\}\n\t\tif b, err := os\.ReadFile\(res\))' '\1clearLaneAbandoned(lane)\n\1\2'
mut "M5 the initial marking removed" TestAbandonedInitialValueIsTheDaemonStartMarking \
  'var abandonedOp = abandonedAtDaemonStart\(\)' 'var abandonedOp = map[string]string{}'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
