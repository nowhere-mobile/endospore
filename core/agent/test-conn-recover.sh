#!/usr/bin/env bash
# test-conn-recover.sh [--mutate] -- NWP-20261203-21: the shared transport pings an idle HTTP/2 conn and closes it when
# the ping gets no answer (applyH2Health in main.go's transport init()), and a timed-out store read drops the pooled idle
# conns at most every dropPooledEvery (dropPooledConnsAfterTimeout at capReadURL and capGetMaxOpt). Runs the focused Go
# tests; --mutate applies each mutant to a pristine copy of main.go or conn_recover.go (both restored on exit) and
# requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp conn_recover.go "$W/conn_recover.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/conn_recover.go.orig" conn_recover.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestSharedTransportPingsHTTP2|TestH2HealthClosesADeadConn|TestTimeoutDropsPooledConns|TestStoreReadErrorPathsDropOnTimeout'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
restore() { cp "$W/main.go.orig" main.go; cp "$W/conn_recover.go.orig" conn_recover.go; }
# mutate <label> <file> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" file="$2" body="$3" o
  restore
  if ! python3 -c "
s = open('$file').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('$file','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); restore; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  restore
}
echo "== mutations =="
mutate "R1: init's applyH2Health call is removed (TestSharedTransportPingsHTTP2)" main.go "
t = s.replace('\t\tapplyH2Health(t, h2PingIdle, h2PingWait)\n', '', 1)"
mutate "R2: applyH2Health sets SendPingTimeout 0 (TestH2HealthClosesADeadConn)" conn_recover.go "
t = s.replace('t.HTTP2.SendPingTimeout = idle', 't.HTTP2.SendPingTimeout = 0', 1)"
mutate "R3: capReadURL's call is removed (TestStoreReadErrorPathsDropOnTimeout)" main.go "
import re
t = re.sub(r'\t\tdropPooledConnsAfterTimeout\(err\)[^\n]*\n', '', s, count=1)"
mutate "R4: capGetMaxOpt's call is removed (TestStoreReadErrorPathsDropOnTimeout)" main.go "
t = s.replace('\t\t\tdropPooledConnsAfterTimeout(gerr)\n', '', 1)"
mutate "R5: the timeout check is inverted (TestTimeoutDropsPooledConns)" conn_recover.go "
t = s.replace('if err == nil || !isTimeoutErr(err) {', 'if err == nil || isTimeoutErr(err) {', 1)"
mutate "R6: the throttle is removed (TestTimeoutDropsPooledConns)" conn_recover.go "
t = s.replace('if last != 0 && now-last < int64(dropPooledEvery) {', 'if false {', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "6 mutants convicted"
