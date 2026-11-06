#!/usr/bin/env bash
# test-roamin-signal-reset.sh [--mutate] -- NWP-20261030-02: a gate sign-in (ROAM-IN, ROAM-IN-OFFLINE) clears the
# departed identity's lastSealStartedAt / lastSealOKAt right after its marker is written; a ROAM-IN refused before its
# marker and a cold-lock RESUME keep them. --mutate applies each mutant to pristine copies of main.go and
# roamsession_marker.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does
# not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp roamsession_marker.go "$W/roamsession_marker.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/roamsession_marker.go.orig" roamsession_marker.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="RoamInSignalReset"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <python body acting on s>: apply to pristine copies, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" body="$3" o
  cp "$W/main.go.orig" main.go
  cp "$W/roamsession_marker.go.orig" roamsession_marker.go
  if ! python3 -c "
s = open('$f').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('$f','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1))
    cp "$W/main.go.orig" main.go; cp "$W/roamsession_marker.go.orig" roamsession_marker.go; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  cp "$W/main.go.orig" main.go; cp "$W/roamsession_marker.go.orig" roamsession_marker.go
}
echo "== mutations =="
CALL='\t\tresetSealSignals()\n'
mutate "R1: handleRoamIn does not reset the signals" main.go "
a = s.index('func handleRoamIn(')
b = s.index('func handleRoamInOffline(')
seg = s[a:b]
assert '$CALL' in seg
t = s[:a] + seg.replace('$CALL', '', 1) + s[b:]"
mutate "R2: handleRoamInOffline does not reset the signals" main.go "
a = s.index('func handleRoamInOffline(')
seg = s[a:]
c = '\tresetSealSignals()\n'
assert c in seg
t = s[:a] + seg.replace(c, '', 1)"
mutate "R3: handleRoamIn resets at the top, beside resetOdWindow, before any refusal" main.go "
a = s.index('func handleRoamIn(')
b = s.index('func handleRoamInOffline(')
seg = s[a:b]
assert '$CALL' in seg
seg = seg.replace('$CALL', '', 1)
o = '\tresetOdWindow()\n'
assert o in seg
seg = seg.replace(o, o + '\tresetSealSignals()\n', 1)
t = s[:a] + seg + s[b:]"
mutate "R4: markRoamSession resets the signals (RESUME and the rotations call it)" roamsession_marker.go "
t = s.replace('resetSealStatus()', 'resetSealStatus()\n\tresetSealSignals()', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
