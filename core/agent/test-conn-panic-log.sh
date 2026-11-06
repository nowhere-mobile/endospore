#!/usr/bin/env bash
# test-conn-panic-log.sh [--mutate] -- NWP-20261106-08: a panic in a daemon verb leaves one scrubbable line in
# login.log (conn_panic.go), with separate budgets for store-unreachable and everything else. --mutate applies each
# mutant to pristine copies of main.go / conn_panic.go (restored on exit) and requires a real `--- FAIL`: a mutant
# that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.orig" || exit 2
cp conn_panic.go "$W/cp.orig" || exit 2
trap 'cp "$W/main.orig" main.go; cp "$W/cp.orig" conn_panic.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestConnPanic|TestNoLogPrintsAProfileNameOutsideQuotes|TestEveryGoroutineGoesThroughGoSafe"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <old> <new>: replace the first <old> in a pristine copy of <file>, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" old="$3" new="$4" res
  cp "$W/main.orig" main.go
  cp "$W/cp.orig" conn_panic.go
  if ! F="$f" OLD="$old" NEW="$new" python3 -c "
import os
f = os.environ['F']
s = open(f).read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "TestConnPanic" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "P1 handleLogin back to the bare recover" main.go 'defer recoverConnPanic() // a malformed' 'defer func() { recover() }() // a malformed'
mutate "P2 the text printed with %s" conn_panic.go 'panic %q (NWP-20261106-08)' 'panic %s (NWP-20261106-08)'
mutate "P3 redactNameIn dropped" conn_panic.go 'text = redactNameIn(text, "")' '_ = redactNameIn'
mutate "P4 the store budget's check removed" conn_panic.go 'case n <= int64(connPanicStoreMax):' 'case true:'
mutate "P5 both kinds on one counter" conn_panic.go 'connPanicStoreN.Add(1)' 'connPanicBugN.Add(1)'
cp "$W/main.orig" main.go
cp "$W/cp.orig" conn_panic.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
