#!/usr/bin/env bash
# test-resume-handoff-se.sh [--mutate] -- runs the resume hand-off secure-element tests (NWP-20261027-01): a cold-lock
# resume opens a tied profile's vault with the marker's secret and stages its sealed telephony. --mutate re-runs them
# against main.go with the secret dropped, passed as nil, or the skipped line removed, restoring the file on exit.
# Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=main.go
RUN=(go test -count=1 -run 'TestTelHandoff|TestHandleResumePassesTheMarkersSecret|TestRollbackInbox|TestLoginAndResumeStageInTheRightMode|TestTelephonyLogLinesQuoteTheName' .)

W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
trap 'cp -f "$W/main.go.orig" "$SRC" 2>/dev/null; rm -rf "$W"' EXIT
cp "$SRC" "$W/main.go.orig"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { cp "$W/main.go.orig" "$SRC"; }
# conv <label>: run the suite against the mutated file, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: Test'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$SRC" "$2" "$3" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
mut "S1 the hand-off opens the vault without the secret" 'dk := openVaultDKSE\(v, name, pass, se\) // pass -> the marker' 'dk := openVaultDK(v, name, pass) // pass -> the marker'
mut "S2 handleResume passes a nil secret" 'telHandoffResume\(name, pass, uid, seFromHex\(se\)\)' 'telHandoffResume(name, pass, uid, nil)'
mut "S3 the skipped line is removed" '\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] resume %q -> telephony hand-off skipped: the vault did not open[^\n]*\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
