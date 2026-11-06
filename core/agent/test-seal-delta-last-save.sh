#!/usr/bin/env bash
# test-seal-delta-last-save.sh [--mutate] -- NWP-20261117-18, #55, backlog row 'Your data's "That save captured ~X across
# N areas" can describe a different save from the "Last saved <ago>" above it': SEAL-DELTA sends lastSaveB / lastSaveN
# only while the manual save they describe is still the last seal to land. --mutate re-runs the tests against main.go /
# seal_delta.go with each rule broken in turn, restoring both on exit. Each mutant must be CONVICTED by a `--- FAIL`;
# one that fails to apply, or fails to compile, counts as a failure. Leaves nothing behind.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go seal_delta.go)
for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
trap 'for f in "${FILES[@]}"; do cp -f "$W/$f.orig" "$f" 2>/dev/null; done; rm -rf "$W"' EXIT
mkdir -p "$W/tmp" "$W/gotmp"
export TMPDIR="$W/tmp" GOTMPDIR="$W/gotmp"
RUN=(go test -count=1 -run 'TestPublishSaveSummary|TestAccumSaveScope|TestSealDeltaLastSave|TestSigninReset|TestSealDeltaScopes' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
out=$(go vet ./... 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAILED go vet"; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { local f; for f in "${FILES[@]}"; do cp "$W/$f.orig" "$f"; done; }
# conv <label>: run the suite against the mutated file, score it, then restore every file.
conv() {
  local res rc
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
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
mut "M1 SEAL-DELTA sends the figures whatever has landed since" seal_delta.go 'seq != 0 && seq == sealLandedSeq\.Load\(\)' 'seq >= 0'
mut "M2 the sequence moves on every verdict" main.go '(\tswitch v := sealVerb\(out\); \{\n\tcase strings\.HasPrefix\(v, "OK"\):\n.*?)\t\tseq = sealLandedSeq\.Add\(1\)[^\n]*\n' '\tseq = sealLandedSeq.Add(1)\n\1'
mut "M3 the manual path publishes the count read before its own verdict" main.go '\tif seq := recordSealLanded\(out\); seq != 0 \{\n\t\tpublishSaveSummary\(comp, seq\)' '\tpre := sealLandedSeq.Load()\n\tif seq := recordSealLanded(out); seq != 0 {\n\t\tpublishSaveSummary(comp, pre)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
