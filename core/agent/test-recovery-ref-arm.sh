#!/usr/bin/env bash
# test-recovery-ref-arm.sh [--mutate] -- runs recovery_ref_armed_test.go (NWP-20261017-31) and recovery_ref_sealpush_test.go (NWP-20261019-10) and recovery_ref_billdrop_test.go (NWP-20261020-07) and billprev_wallet_test.go (NWP-20261114-07); --mutate re-runs it against
# main.go with each arm broken in turn, restoring the file on exit. Each mutant must be CONVICTED (a `--- FAIL`); one
# that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestRecoveryRefArm_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement> [<FAIL tests> [<PASS tests>]]
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [ $# -ge 4 ]; then # exact verdicts: every test in $4 (it may list none) must FAIL, every test in $5 must PASS
    local t bad=""
    for t in $4; do grep -q -- "^--- FAIL: $t " <<<"$res" || bad="$bad $t(not FAIL)"; done
    for t in ${5:-}; do grep -q -- "^--- PASS: $t " <<<"$res" || bad="$bad $t(not PASS)"; done
    if [ -z "$bad" ]; then echo "  convicted $1"; else echo "  SURVIVED  $1 --$bad"; fails=$((fails+1)); fi
  elif grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1 (no --- FAIL: survived or did not compile)"; fails=$((fails+1)); fi
  cp "$MAIN.orig" "$MAIN"
}
mut "M1 the recovery-ref arm removed" 'if h\.rref != "" \{\n\t\tcapExpect\(op, h\.rref, h\.rold\)\n\t\}' ''
mut "M2 armed at the NEW value, not the one read" 'capExpect\(op, h\.rref, h\.rold\)' 'capExpect(op, h.rref, getRef("s3", h.rref))'
mut "M3 armed at the head value, not the recovery ref's own value" 'h\.rold = getRef\(base, h\.rref\)' 'h.rold = val'
mut "M4 the seal's recovery-ref arm removed" 'expectRef\(v\.RecoveryRef, getRef\(base, v\.RecoveryRef\)\)\n' '' \
  "TestRecoveryRefArm_SealBothMoved TestRecoveryRefArm_SealRecoveryOnlyMoved" "TestRecoveryRefArm_SealNothingMovedLandsBoth"

PASS_PREV=TestRecoveryRefArm_BillDropPrevNothingOutstanding; PASS_RTG=TestRecoveryRefArm_BillDropRetagNothingOutstanding
mut "M5 dropBillPrev's recovery-ref publish removed" '("plan carry clear".*?)\n\t\tif cur\.RecoveryRef != "" && !putRefBytesGuarded\(base, cur\.RecoveryRef, \[\]byte\(vh\), mayWrite\) \{\n\t\t\tperr = errLateWriteDenied\n\t\t\}\n' '\1\n' \
  "TestRecoveryRefArm_BillDropPrevMovesBoth TestRecoveryRefArm_BillDropPrevBehindAnotherBracket" \
  "TestRecoveryRefArm_BillDropRetagMovesBoth TestRecoveryRefArm_BillDropRetagBehindAnotherBracket $PASS_PREV $PASS_RTG"
mut "M6 dropBillRetag's recovery-ref publish removed" '("re-tag clear".*?)\n\t\tif cur\.RecoveryRef != "" \{\n\t\t\tputRef\(base, cur\.RecoveryRef, vh\)\n\t\t\}\n' '\1\n' \
  "TestRecoveryRefArm_BillDropRetagMovesBoth TestRecoveryRefArm_BillDropRetagBehindAnotherBracket" \
  "TestRecoveryRefArm_BillDropPrevMovesBoth TestRecoveryRefArm_BillDropPrevBehindAnotherBracket $PASS_PREV $PASS_RTG"
mut "M7 dropBillPrev republishes the recovery ref's current value" '("plan carry clear".*?putRefBytesGuarded\(base, cur\.RecoveryRef, )\[\]byte\(vh\)' '\1[]byte(getRef(base, cur.RecoveryRef))' \
  "TestRecoveryRefArm_BillDropPrevMovesBoth TestRecoveryRefArm_BillDropPrevBehindAnotherBracket" \
  "TestRecoveryRefArm_BillDropRetagMovesBoth TestRecoveryRefArm_BillDropRetagBehindAnotherBracket $PASS_PREV $PASS_RTG"
mut "M8 the plan-carry clear counts the wallet as ours" \
  'vd := capWriteAttr\(name, pass, dk, true, func\(\) \{(\n\t\tcapSetSessionMayWrite\(mayWrite\)[^\n]*\n\t\tcur, err := capReadVaultForEdit\(base, "plan carry clear")' \
  'vd := capWrite(name, pass, dk, func() {\1' \
  "TestRecoveryRefArm_BillDropPrevNeverFoldsAStrangersWallet" \
  "TestRecoveryRefArm_BillDropPrevMovesBoth TestRecoveryRefArm_BillDropRetagMovesBoth"
# M9 is the control that M8's anchor is specific: the same edit on dropBillRetag's bracket leaves the new test green.
mut "M9 control: the same mutation on dropBillRetag's bracket" \
  'vd := capWriteAttr\(name, pass, dk, true, func\(\) \{(\n\t\tcur, err := capReadVaultForEdit\(base, "re-tag clear")' \
  'vd := capWrite(name, pass, dk, func() {\1' \
  "" \
  "TestRecoveryRefArm_BillDropPrevNeverFoldsAStrangersWallet TestRecoveryRefArm_BillDropRetagMovesBoth"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
