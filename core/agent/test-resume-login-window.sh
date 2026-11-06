#!/usr/bin/env bash
# test-resume-login-window.sh [--mutate] -- a cold-lock resume closes the login window to the tail at its OK reply
# (NWP-20261026-02). Plain: the resume-window tests plus the cold-resume / defer / backup / tie suites they sit beside.
# --mutate applies each mutant to main.go in place (a pristine copy lives in one temp root, restored after every mutant
# and on exit) and runs the resume-window tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails to
# apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
restore() { [ -f "$W/main.go" ] && cp -f "$W/main.go" main.go; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'ResumeLoginWindow|CloseLoginWindow|ColdResume|RefusedResume|SyncDefer|LoginWindow|BackupBusy|HandleBackup|TieProgress|FinishTie' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go"
fails=0
A=TestResumeLoginWindowClosesToTheTailAtTheReply
B=TestResumeLoginWindowARefusedResumeLeavesItAsItWas
C=TestCloseLoginWindowOnlyClosesAnOpenWindow
D=TestResumeLoginWindowSourcePins
CALL=$'\tcloseLoginWindow(uid)\n'
# The resume's call is the only one preceded by the NWP-20261026-02 comment's last line.
RCALL=$'leaves the window as it is.\n'"$CALL"
# mut <label> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" old="$2" new="$3" res want
  shift 3
  python3 - main.go "$old" "$new" "${PRE_OLD:-}" "${PRE_NEW:-}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new, pre_old, pre_new = sys.argv[1:6]
s = open(p).read()
if pre_old:
    if s.count(pre_old) != 1:
        sys.exit(1)
    s = s.replace(pre_old, pre_new)
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -run 'ResumeLoginWindow|CloseLoginWindow' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "R1 the resume's closeLoginWindow call removed" "$RCALL" $'leaves the window as it is.\n' $A $D
# R2 moves the call: the after-reply one goes (inside mut, as a second edit via PRE), the early one is added.
PRE_OLD="$RCALL" PRE_NEW=$'leaves the window as it is.\n'
mut "R2 the call placed before armLoginWindow" $'\tarmLoginWindow("resume", uid, true)\n' $'\tcloseLoginWindow(uid)\n\tarmLoginWindow("resume", uid, true)\n' $A $D
PRE_OLD="" PRE_NEW=""
mut "R3 the IsZero guard dropped" $'\tif !loginSettleUntil.IsZero() {\n\t\tloginSettleUntil = time.Now().Add(loginWindowTail)' $'\tif true {\n\t\tloginSettleUntil = time.Now().Add(loginWindowTail)' $C
mut "R4 closeLoginWindow sets the cap" $'\t\tloginSettleUntil = time.Now().Add(loginWindowTail)\n\t\telapsed, deferred' $'\t\tloginSettleUntil = time.Now().Add(loginWindowCap)\n\t\telapsed, deferred' $A $C
mut "R5 a refused resume reaches the call (right after readColdLock, the earliest point uid exists)" $'\tname, uid, se, needKey, hasPin, passWrap := readColdLock(dest)\n' $'\tname, uid, se, needKey, hasPin, passWrap := readColdLock(dest)\n\tcloseLoginWindow(uid)\n' $B $D
mut "R6 handleGrantPerms's closeLoginWindow call removed" $'inside the 15s tail.\n\tcloseLoginWindow(uid)\n' $'inside the 15s tail.\n' $D
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
