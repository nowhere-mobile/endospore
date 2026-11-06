#!/usr/bin/env bash
# test-gate-log-in-bucket.sh [--mutate] -- runs the gate.log tests that pin `in=` as one of four buckets (NWP-20261115-13,
# decision #33 2026-10-22); --mutate re-runs them against gate_log.go with gateInBucket or its use in gateLog broken in
# turn, restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
GL=gate_log.go
RUN=(go test -count=1 -run 'TestGateLog|TestGateAlarmInSeconds|TestGateTraceLine' -v .)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"; [ ! -f "$GL.orig" ] || mv -f "$GL.orig" "$GL"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$GL" "$GL.orig"
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local res mrc
  python3 - "$GL" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$GL.orig" "$GL"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  cp "$GL.orig" "$GL"
}
mut "B1 gateLog writes the raw integer for in" '"=" \+ gateInBucket\(val\)' '"=" + strconv.Itoa(val)'
mut "B2 the past edge < 0 becomes <= 0" 'case sec < 0:' 'case sec <= 0:'
mut "B3 the 1 h edge 3600 becomes 3601" 'case sec < 3600:' 'case sec < 3601:'
mut "B4 the 12 h edge made exclusive" 'case sec <= 43200:' 'case sec < 43200:'
mut "B5 over12h written as 1to12h" 'default:\n\t\treturn "over12h"' 'default:
		return "1to12h"'
mut "B6 the bucket applied to ms as well" 'if key == "in" \{' 'if key == "in" || key == "ms" {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
