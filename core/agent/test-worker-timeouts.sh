#!/usr/bin/env bash
# test-worker-timeouts.sh [--mutate] -- runs worker_timeouts_test.go (NWP-20261204-16, Q182): runWorkerHeld's
# ERR-TIMEOUT exits count each expiry, whether a lost-start re-fire came first and whether the request was still
# unread; noteLostStart counts by op; an issue report carries both at every scope. --mutate re-runs it with each part
# broken in turn (main.go, report_issue.go, worker_timeouts.go), restoring the three files on exit. Each mutant must be
# CONVICTED by the named test's `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
cp main.go report_issue.go worker_timeouts.go "$W"/ || exit 2
trap 'cp -f "$W/main.go" "$W/report_issue.go" "$W/worker_timeouts.go" . 2>/dev/null; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run '^(TestWorkerTimeouts_|TestIssueReportCarriesWorkerTimeouts$)' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

restore() { cp -f "$W/main.go" "$W/report_issue.go" "$W/worker_timeouts.go" .; }
fails=0
total=0
mut() { # mut <label> <file> <expected failing test> <python-regex pattern> <replacement>
  local label="$1" file="$2" want="$3" res
  total=$((total+1))
  python3 - "$file" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $want "* ]]; then echo "  convicted $label"
  else echo "  SURVIVED  $label"; tail -n 15 <<<"$res"; fails=$((fails+1)); fi
  restore
}
mut "W1 the expiry count removed from timedOut" main.go TestWorkerTimeouts_RefiredStartStillUnanswered \
  '\t+noteWorkerTimeout\(op, refired > 0, rerr == nil\)\n' '\t\t_, _ = refired, rerr\n'
mut "W2 afterLostStart passed as false" main.go TestWorkerTimeouts_RefiredStartStillUnanswered \
  'noteWorkerTimeout\(op, refired > 0,' 'noteWorkerTimeout(op, refired < 0,'
mut "W3 unconsumed passed as true always" main.go TestWorkerTimeouts_RefiredStartStillUnanswered \
  'noteWorkerTimeout\(op, refired > 0, rerr == nil\)' 'noteWorkerTimeout(op, refired > 0, rerr == nil || true)'
mut "W4 unconsumed passed inverted" main.go TestWorkerTimeouts_HungInstanceUnconsumed \
  'noteWorkerTimeout\(op, refired > 0, rerr == nil\)' 'noteWorkerTimeout(op, refired > 0, rerr != nil)'
mut "W5 refired++ removed" main.go TestWorkerTimeouts_RefiredStartStillUnanswered \
  '(\t+noteLostStart\(op\)\n)\t+refired\+\+\n' '\1'
mut "W6 the per-op count removed from noteLostStart" main.go TestWorkerTimeouts_ByOpTokensAndCap \
  '\tnoteLostStartOp\(op\)\n' ''
mut "W7 the op sanitiser removed" worker_timeouts.go TestWorkerTimeouts_ByOpTokensAndCap \
  'if opTokenRe\.MatchString\(op\) \{' 'if true {'
mut "W8 the list cap removed" worker_timeouts.go TestWorkerTimeouts_ByOpTokensAndCap \
  'const opListCap = 12' 'const opListCap = 1000'
mut "W9 the report keys gated on !deviceScope" report_issue.go TestIssueReportCarriesWorkerTimeouts \
  '(\tstatus\["roam_worker_timeouts"\] = workerTimeoutsValue\(\)\n\tstatus\["roam_lost_starts_by_op"\] = lostStartsByOpValue\(\)\n)' \
  '\tif !deviceScope {\n\1\t}\n'
mut "W10 the roam_lost_starts_by_op key removed" report_issue.go TestIssueReportCarriesWorkerTimeouts \
  '\tstatus\["roam_lost_starts_by_op"\] = lostStartsByOpValue\(\)\n' ''
mut "W11 the roam_worker_timeouts key removed" report_issue.go TestIssueReportCarriesWorkerTimeouts \
  '\tstatus\["roam_worker_timeouts"\] = workerTimeoutsValue\(\)\n' ''
[ "$fails" -eq 0 ] && echo "== all $total mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
