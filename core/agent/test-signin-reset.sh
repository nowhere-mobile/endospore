#!/usr/bin/env bash
# test-signin-reset.sh [--mutate] -- NWP-20261108-03: a new sign-in's Your data carries nothing of the last session.
# resetSealSignals also clears lastSaveBytes / lastSaveAreas, sealDeferCount and both SEAL-DELTA caches, and a
# stored-apps refresh kicked before the reset publishes nothing; a RESUME keeps all of it. --mutate applies each
# mutant to pristine copies of main.go, seal_delta.go and roamsession_marker.go (restored on exit) and requires a
# real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp seal_delta.go "$W/seal_delta.go.orig" || exit 2
cp roamsession_marker.go "$W/roamsession_marker.go.orig" || exit 2
restore() {
  cp "$W/main.go.orig" main.go
  cp "$W/seal_delta.go.orig" seal_delta.go
  cp "$W/roamsession_marker.go.orig" roamsession_marker.go
}
trap 'restore; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestSigninReset"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <python body acting on s, setting t>: apply to pristine copies, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" body="$3" o
  restore
  if ! python3 -c "
s = open('$f').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('$f','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1))
    restore; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  restore
}
# drop <text>: inside func resetSealSignals, remove the text (once)
drop() {
  printf '%s' "
a = s.index('func resetSealSignals(')
b = s.index('\nfunc ', a + 1)
seg = s[a:b]
assert seg.count('$1') == 1
t = s[:a] + seg.replace('$1', '', 1) + s[b:]"
}
echo "== mutations =="
mutate "D1: the lastSave reset is dropped" main.go "$(drop '\tlastSaveBytes.Store(0)\n\tlastSaveAreas.Store(0)\n')"
mutate "D2: the sealDeferCount reset is dropped" main.go "$(drop '\tsealDeferCount.Store(0)\n')"
mutate "D3: resetSealDeltaCaches is not called" main.go "$(drop '\tresetSealDeltaCaches()\n')"
mutate "D4: the generation check is removed from the publish" seal_delta.go "
c = 'if c.gen != gen {'
assert s.count(c) == 1
t = s.replace(c, 'if c.gen != gen && false {', 1)"
mutate "D5: markRoamSession resets the seal signals (a RESUME and a rotation call it)" roamsession_marker.go "
c = 'resetSealStatus()'
assert s.count(c) >= 1
t = s.replace(c, 'resetSealStatus()\n\tresetSealSignals()', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
