#!/usr/bin/env bash
# test-idle-trace.sh [--mutate] -- runs idle_trace_test.go (NWP-20261106-19); --mutate re-runs it against idle_trace.go and
# main.go with the IDLE-TRACE vocabulary broken in turn (I1 any word kept, I2 a key's value not digits, I3 `screen` not a
# verb, I4 the arm printing the raw filtered text, I5 `installs` not a verb), restoring both files on exit. Each mutant
# must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
IT=idle_trace.go
MAIN=main.go
RUN=(go test -count=1 -run '^TestIdleTrace' .)

W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp "$IT" "$W/idle_trace.go.orig"
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/idle_trace.go.orig" "$IT" 2>/dev/null; cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { cp "$W/idle_trace.go.orig" "$IT"; cp "$W/main.go.orig" "$MAIN"; }
# conv <label>: run the suite against the mutated tree, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: TestIdleTrace'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <file> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$2" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
mut "I1 any [a-z0-9] word kept" "$IT" 'if idleTraceWords\[tok\] \{' 'if true {'
mut "I2 a key value not required to be digits" "$IT" 'idleTraceKeys\[k\] && idleTraceInt\(v\)' 'idleTraceKeys[k] && (idleTraceInt(v) || true)'
mut "I3 screen removed from the verbs" "$IT" '"screen": true, ("arm": true, "cancel")' '\1'
mut "I4 the arm prints the raw filtered text" "$MAIN" 'idleTraceLine\(ev\); line != ""' 'idleTraceFilter(ev); line != ""'
mut "I5 installs removed from the verbs" "$IT" '"fire": true, "installs": true, ' '"fire": true, '
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
