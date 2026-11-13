#!/usr/bin/env bash
# test-coldlock-alarm-read.sh [--mutate] -- NWP-20261129-26: GET-GATE-ALARM waits, bounded, from a cold lock's commit
# until its at-lock relay ends, so the gate's one read of the stash cannot come before the relay lands. --mutate re-runs
# the named test against a COPY of the package with each part broken in turn. Each mutant must be CONVICTED by a
# `--- FAIL` of that test; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestColdLockAlarmRead' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# apply <file> <python-regex> <replacement>: one match exactly, or it fails.
apply() {
  python3 - "$1" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
}
# mut <label> <test> <file> <python-regex> <replacement>: apply to the copy, run only <test> there, then restore the
# file. One test per mutant: under M4 R1's SET waits too, and a whole-file run would stall its teardown for the bound.
mut() {
  local label="$1" test="$2" f="$3" res
  cp "$P/$f" "$W/orig.go"
  if apply "$P/$f" "$4" "$5"; then
    res=$(cd "$P" && go test -count=1 -run "^$test\$" . 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *"--- FAIL: $test"* ]]; then echo "  convicted $label ($test)"
    else echo "  SURVIVED  $label ($test)"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 the prologue call removed" TestColdLockAlarmReadWaitsForTheRelay main.go \
  '\twaitForAtLockRelay\(name\)[^\n]*\n' ''
mut "M2 beginAtLockRelay moved below the switch publish" TestColdLockAlarmReadSourceOrder main.go \
  '\tbeginAtLockRelay\(\)\n(.*?\tpendingSwitchUID = uid // phase 1: switch to the gate\n\tpendingReapMu\.Unlock\(\)\n)' \
  '\1\tbeginAtLockRelay()\n'
mut "M3 endAtLockRelay removed" TestColdLockAlarmReadRelayEndsBeforeTheSweep main.go \
  '\tendAtLockRelay\(\)\n' ''
mut "M4 waitForAtLockRelay waits for every verb" TestColdLockAlarmReadOnlyGetInARelayWaits coldlock_evict.go \
  'if name != "GET-GATE-ALARM" \|\| !atLockRelayInFlight\(\) \{' 'if !atLockRelayInFlight() {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
