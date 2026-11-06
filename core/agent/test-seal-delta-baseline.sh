#!/usr/bin/env bash
# test-seal-delta-baseline.sh [--mutate] -- NWP-20261108-05: SEAL-DELTA-WALK's rule-B baseline is the dispatch of the last
# seal that LANDED. --mutate re-runs the tests against main.go / seal_delta.go with each guard broken in turn, restoring
# both on exit. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a
# failure. Leaves nothing behind.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig"
cp seal_delta.go "$W/seal_delta.go.orig"
trap 'cp -f "$W/main.go.orig" main.go 2>/dev/null; cp -f "$W/seal_delta.go.orig" seal_delta.go 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/tmp" "$W/gotmp"
export TMPDIR="$W/tmp" GOTMPDIR="$W/gotmp"
RUN=(go test -count=1 -run 'TestSealDeltaBaseline' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { cp "$W/main.go.orig" main.go; cp "$W/seal_delta.go.orig" seal_delta.go; }
# conv <label>: run the suite against the mutated file, then restore both files.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: Test'* ]]; then echo "  convicted $1"
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
mut "M1 the walk's baseline is the last announce again" seal_delta.go 'since := lastLandedSealStartedAt\.Load\(\)' 'since := lastSealStartedAt.Load()'
mut "M2 noteSealLanded records any verdict" main.go '(func noteSealLanded\(start int64, out string\) \{\n\t)if !strings\.HasPrefix\(sealVerb\(out\), "OK"\) \{' '\1if false {'
mut "M3 the periodic arm passes the announce stamp read at verdict time" main.go 'noteSealLanded\(periodicSealStartedAt\.Load\(\), out\)' 'noteSealLanded(lastSealStartedAt.Load(), out)'
mut "M4 resetSealSignals keeps the landed stamp" main.go '(func resetSealSignals\(\) \{.*?)\n\tlastLandedSealStartedAt\.Store\(0\)' '\1'
mut "M5 the NOBASE test never fires" seal_delta.go '(since := lastLandedSealStartedAt\.Load\(\)\n\t)if since == 0 \{' '\1if since < 0 {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
