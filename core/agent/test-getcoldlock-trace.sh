#!/usr/bin/env bash
# test-getcoldlock-trace.sh [--mutate] -- runs getcoldlock_trace_test.go (NWP-20261129-36); --mutate re-runs it against
# main.go with GET-COLDLOCK's log lines broken in turn, restoring the file on exit. Each mutant must be CONVICTED with
# a --- FAIL; one that does not apply or does not compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
F=main.go
RUN=(go test -count=1 -run 'TestGetColdLockTrace_' .)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/orig"
trap 'cp -f "$W/orig" "$F"; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local o r
  python3 - "$F" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
  o=$("${RUN[@]}" 2>&1); r=$?
  score_mutant "$1" "$r" "$o" || fails=$((fails+1))
  cp -f "$W/orig" "$F"
}
mut "M1 the NONE line is removed" '\n\t*fmt\.Fprintf\(os\.Stderr, "\[logind\] GET-COLDLOCK: answered NONE while[^\n]*' ''
mut "M2 the once-per-lock guard is removed" 'firstNone := tr\.nones == 1' 'firstNone := tr.nones > 0'
mut "M3 the NONE line prints with no teardown running" 'if lockRunning && lockTrace\(\) \{' 'if (lockRunning || true) && lockTrace() {'
mut "M4 the offered lines are removed" 'if offerN <= 3 \{' 'if offerN < 1 {'
mut "M5 the three-answer cap is removed" 'if offerN <= 3 \{' 'if offerN <= 4 {'
mut "M6 the NONE count ignores which uid the lock named" 'if tr\.noneUID == uid \{' 'if tr.noneUID != "" {'
mut "M7 a new coldLockStarts value does not start a new count" 'if lockStarts > tr\.starts \{' 'if false {'
mut "M8 a call from an older lock writes into the newer lock's trace" 'if lockStarts < tr\.starts \{' 'if false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
