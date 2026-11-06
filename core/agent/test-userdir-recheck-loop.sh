#!/usr/bin/env bash
# test-userdir-recheck-loop.sh [--mutate] -- NWP-20261107-12 (Q037): the login daemon's 5-minute userdirrecheck tick, sent
# only while roamd's $STATE/userdir-pending is non-empty. Runs the focused Go tests; --mutate applies each mutant to a
# package copy under the suite's one temp root and requires a real `--- FAIL`: a mutant that does not apply, or that does
# not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestUserdirRecheck"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <old> <new>: apply to a package copy (old must occur exactly once), require a real --- FAIL
mutate() {
  local lbl="$1" file="$2" old="$3" new="$4" P o
  P=$(mktemp -d -p "$W") || { echo "  FAIL  no temp dir: $lbl"; FAILS=$((FAILS+1)); return; }
  cp -a . "$P/" || { echo "  FAIL  copy failed: $lbl"; FAILS=$((FAILS+1)); rm -rf "$P"; return; }
  if ! (cd "$P" && F="$file" OLD="$old" NEW="$new" python3 -c "
import os
f = os.environ['F']; s = open(f).read(); old = os.environ['OLD']
if s.count(old) != 1: raise SystemExit('mutant anchor occurs %d times' % s.count(old))
open(f, 'w').write(s.replace(old, os.environ['NEW']))"); then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); rm -rf "$P"; return
  fi
  o=$(cd "$P" && go test -count=1 -run "$RUN" -v . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  rm -rf "$P"
}
echo "== mutations =="
mutate "L1: the file check removed" userdir_recheck_loop.go \
  'if err != nil || !fi.Mode().IsRegular() || fi.Size() == 0 {' 'if false && (err != nil || !fi.Mode().IsRegular() || fi.Size() == 0) {'
mutate "L2: the interval 5 min -> 1 min" userdir_recheck_loop.go 'userdirRecheckEvery = 5 * time.Minute' 'userdirRecheckEvery = 1 * time.Minute'
mutate "L3: the wait cap removed" main.go '	case "userdirrecheck":' '	case "userdirrecheck-off":'
mutate "L4: the loop start removed" main.go '	goSafeLoop("userdir-recheck loop", func() { userdirRecheckLoop(dest) })
' ''
mutate "L5: the tick removed from the loop" userdir_recheck_loop.go '		userdirRecheckTick(dest)
' ''
mutate "L6: the loop sleeps 1 min, not the constant" userdir_recheck_loop.go \
  'userdirRecheckSleep(userdirRecheckEvery)' 'userdirRecheckSleep(time.Minute)'
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
