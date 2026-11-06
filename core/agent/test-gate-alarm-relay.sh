#!/usr/bin/env bash
# test-gate-alarm-relay.sh [--mutate] -- runs gate_alarm_relay_test.go (NWP-20261028-05); --mutate re-runs it
# against main.go / gate_log.go with each guard of the SET-GATE-ALARM handler broken in turn, restoring the files
# on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
MAIN=main.go; GL=gate_log.go
trap 'rm -rf "$W"; for f in "$MAIN" "$GL"; do [ -f "$f.orig" ] && mv -f "$f.orig" "$f"; done' EXIT
export TMPDIR="$W"
RUN=(go test -count=1 -run 'TestGateAlarmRelay_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -15
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

for f in "$MAIN" "$GL"; do cp "$f" "$f.orig"; done
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local res
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  for f in "$MAIN" "$GL"; do cp "$f.orig" "$f"; done
}
mut "M1 number check removed" "$MAIN" 'perr != nil \|\| n == 0 \{' 'false && (perr != nil || n == 0) {'
mut "M2 time write error discarded" "$MAIN" 'else if err := os\.WriteFile\(p, \[\]byte\(when\), 0o600\); err != nil \{' 'else if _ = os.WriteFile(p, []byte(when), 0o600); false {'
mut "M3 owner write failure answers ERR" "$MAIN" '// The reply stays OK:[^\n]*\n' 'reply = "ERR\n"
'
mut "M4 clear remove error discarded" "$MAIN" 'if err := os\.Remove\(p\); err != nil && !errors\.Is\(err, fs\.ErrNotExist\) \{' 'if err := os.Remove(p); false && err != nil {'
mut "M5 relay-err not a known verb" "$GL" '"relay-err": true, ' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
