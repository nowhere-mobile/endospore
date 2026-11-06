#!/usr/bin/env bash
# test-gate-timing-vocab.sh [--mutate] -- runs gate_timing_test.go (NWP-20261118-19): GATE-TIMING logs only a phase of
# gateTimingPhases, the phases the gate sends, and that set stays in step with the chooser's gateTiming call sites.
# --mutate re-runs it with main.go or gate_timing_test.go broken in turn (G1 gatePhaseOK back to the charset, G2 a phase
# dropped from the set, G3 the coverage test's minimum-call check removed AND its scanned method name misspelt, G4 the
# handler no longer calling gatePhaseOK), restoring main.go and gate_timing_test.go on exit. Each mutant must be
# CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
GT=gate_timing_test.go
RUN=(go test -count=1 -run '^TestGatePhaseOK$|^TestGateTiming' .)

W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp "$MAIN" "$W/main.go.orig"
cp "$GT" "$W/gate_timing_test.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; cp -f "$W/gate_timing_test.go.orig" "$GT" 2>/dev/null; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { cp "$W/main.go.orig" "$MAIN"; cp "$W/gate_timing_test.go.orig" "$GT"; }
# conv <label>: run the tests against the mutated tree, score the run, then restore both files.
conv() {
  local res rc
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <file> <pattern> <replacement> [<pattern> <replacement> ...]: every python regex pattern must match
# exactly once, or the mutant is INERT.
mut() {
  local label="$1" file="$2"
  shift 2
  python3 - "$file" "$@" <<'PY' || { inert "$label"; return; }
import re,sys
p=sys.argv[1]
pairs=sys.argv[2:]
if not pairs or len(pairs)%2: sys.exit(1)
s=open(p).read()
for pat,rep in zip(pairs[::2],pairs[1::2]):
    if len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
    n=re.sub(pat,rep,s,count=1,flags=re.S)
    if n==s: sys.exit(1)
    s=n
open(p,'w').write(s)
PY
  conv "$label"
}
mut "G1 gatePhaseOK back to the charset" "$MAIN" \
  'return gateTimingPhases\[s\]' \
  'return s != "" && len(s) <= 24 && s[0] >= '"'a'"' && s[0] <= '"'z'"' && strings.Trim(s, "abcdefghijklmnopqrstuvwxyz0123456789-") == ""'
mut "G2 dozeapply dropped from the set" "$MAIN" \
  '"clear-restrictions": true, "dozeapply": true,' '"clear-restrictions": true,'
mut "G3 no minimum-call check and the scanned name misspelt" "$GT" \
  '\n\tif calls < gateTimingMinCalls \{.*?\n\t\}\n' '\n' \
  'idleTraceCalls\(string\(raw\), "gateTiming"\)' 'idleTraceCalls(string(raw), "gateTimng")'
mut "G4 the handler no longer calls gatePhaseOK" "$MAIN" \
  '!gatePhaseOK\(phase\)' 'phase == ""'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
