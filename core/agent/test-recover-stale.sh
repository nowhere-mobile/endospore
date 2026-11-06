#!/usr/bin/env bash
# test-recover-stale.sh [--mutate] -- runs the TestRecoverStale tests (NWP-20261116-06, backlog row "A 12-word recovery
# overwrites a seal another signed-in handset landed while it ran"); --mutate re-runs the one test that must convict
# each mutant against main.go with one piece of the recovery's stale check broken, restoring the file on exit. Each
# mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=main.go

out=$(go test -count=1 -run 'TestRecoverStale' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$SRC" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$SRC" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/main.go.orig" "$SRC"; }
# mut <label> <test> <pattern> <replacement> [<pattern> <replacement>]...: each python-regex pattern must match
# exactly once, or the mutant is INERT; then <test> runs against the mutated file and must fail.
mut() {
  local label="$1" test="$2" res rc
  shift 2
  if ! python3 - "$SRC" "$@" <<'PY'
import re,sys
p=sys.argv[1]; a=sys.argv[2:]
s=open(p).read()
for pat,rep in zip(a[0::2],a[1::2]):
    if len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
    s=re.sub(pat,rep,s,count=1,flags=re.S)
open(p,'w').write(s)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return
  fi
  res=$(go test -count=1 -run "^${test}\$" . 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  restore
}
ARM='\t\tcapExpectGate\("recover", rref, head\)\n'
REREAD='\t\tif got := getRef\(base, rref\); got != head \{\n\t\t\tnoteOpRefused\("recover", rref, head, got, true\)\n\t\t\tcapAbort\(\)[^\n]*\n\t\t\treturn\n\t\t\}\n'
T1=TestRecoverStale_SealBeforeTheBracketRefuses
T2=TestRecoverStale_SealInsideTheBracketRefuses
T5=TestRecoverStale_ArmedUnderMultiDevice
T6=TestRecoverStale_SealBeforeTheRecoveryRefIsBufferedRefuses
mut "M1 the arming removed" "$T2" "$ARM" ''
mut "M2 the in-bracket re-read removed" "$T1" "$REREAD" ''
mut "M3 armed at the in-bracket value, not at head" "$T1" "($ARM)" '\t\thead = getRef(base, rref)\n\1'
mut "M4 the arming and re-read skipped under NOWHERE_MULTIDEVICE" "$T5" "($ARM$REREAD)" '\t\tif !multiDeviceEnabled() {\n\1\t\t}\n'
mut "M5 the ERR-MOVED case after the ERR-STORE case" "$T1" \
  '(\tcase errors\.Is\(err, errRecoverMoved\):[^\n]*\n\t\treturn "ERR-MOVED"\n)(\tcase errors\.Is\(err, errRecoverAfterUnwrap\):\n\t\treturn "ERR-STORE"\n)' '\2\1'
mut "M6 the stale refusal wrapped without errRecoverMoved" "$T1" \
  'errRecoverAfterUnwrap, errRecoverMoved\)' 'errRecoverAfterUnwrap, errors.New("moved"))'
mut "M7 capExpectGate marks no gate (the flush withholds only the refused ref)" "$T2" \
  '(capCur\.gates\["ref/"\+strings\.TrimPrefix\(ref, "ref/"\)\] = )true' '\1false'
mut "M8 the recovery ref buffered after the heads again" "$T2" \
  '\t\tputRef\(base, rref, vh\)\n(\t\tsealExpectMu\.Lock\(\)\n\t\tgateRefused)' '\1' \
  '(\t\t// ⚠ A RECOVERY SUPERSEDES SCOPE HEADS)' '\t\tputRef(base, rref, vh)\n\1'
mut "M9 a recovery ref refused at the buffer does not stop the heads" "$T6" \
  'gateRefused := sealStaleHit \|\| sealFenceHit' 'gateRefused := false'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
