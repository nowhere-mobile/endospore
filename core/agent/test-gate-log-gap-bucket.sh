#!/usr/bin/env bash
# test-gate-log-gap-bucket.sh [--mutate] -- runs the gate.log tests that pin `d=`, `m=` and `s=` as buckets, never an exact
# elapsed time (NWP-20261123-18, h53 #7 2026-11-02); --mutate re-runs them against gate_log.go with gateGapBucket,
# gateSuspendSeconds or their use in gateLog broken in turn, restoring the file on exit. Each mutant must be CONVICTED
# by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
GL=gate_log.go
RUN=(go test -count=1 -run 'TestGateLog|TestGateGapBucket|TestGateAlarm' -v .)
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
mut "M1 the 10 s edge off by one" 'case sec < 10:' 'case sec < 11:'
mut "M2 gateLog writes the raw integer for d" '"d=" \+ gateGapBucket\(d\)' '"d=" + strconv.Itoa(d)'
mut "M3 s taken from d - m with no rounding rule" 's >= 2 \{' 's > 0 {'
mut "M4 s= dropped" ' \+ " s=" \+ gateGapBucket\(gateSuspendSeconds\(d, m\)\)' ''
mut "M5 the zero bucket made exclusive" 'case sec <= 0:' 'case sec < 0:'
mut "M6 the 1 h edge off by one" 'case sec < 3600:\n\t\treturn "lt1h"' 'case sec < 3601:
		return "lt1h"'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
