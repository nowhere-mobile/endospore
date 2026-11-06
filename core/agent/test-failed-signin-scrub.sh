#!/usr/bin/env bash
# test-failed-signin-scrub.sh [--mutate] -- NWP-20261027-02: a failed sign-in (BLANK / BLANK NET) schedules roamd's
# `logscrub` op after its reply. Runs the focused Go tests; --mutate applies each mutant to a pristine copy of main.go
# (swapped in for the run, restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does
# not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="FailedSigninScrub|CredLaneMembership"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
printf '%s\n' "$out" | tail -15
[ "$rc" = 0 ] || { echo "FAIL: the focused tests fail"; exit 1; }
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
CALL='scheduleFailedSigninScrub(dest) // NWP-20261027-02'
# mutate <label> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" body="$2" o
  cp "$W/main.go.orig" main.go
  if ! CALL="$CALL" python3 -c "
import os
s = open('main.go').read(); call = os.environ['CALL']; t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('main.go','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); cp "$W/main.go.orig" main.go; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  cp "$W/main.go.orig" main.go
}
echo "== mutations =="
mutate "G1: the BLANK NET call removed" "
t = s.replace('\t\tfmt.Fprint(conn, \"BLANK NET\\\\n\")\n\t\t' + call + '\n', '\t\tfmt.Fprint(conn, \"BLANK NET\\\\n\")\n', 1)"
mutate "G2: the BLANK call removed" "
t = s.replace('\t\tfmt.Fprint(conn, \"BLANK\\\\n\")\n\t\t' + call + '\n', '\t\tfmt.Fprint(conn, \"BLANK\\\\n\")\n', 1)"
mutate "G3: the BLANK call moved before the reply" "
t = s.replace('\t\tfmt.Fprint(conn, \"BLANK\\\\n\")\n\t\t' + call + '\n', '\t\t' + call + '\n\t\tfmt.Fprint(conn, \"BLANK\\\\n\")\n', 1)"
mutate "G4: the call added to the ERR-TIMEOUT branch" "
t = s.replace('\t\tfmt.Fprint(conn, \"ERR-TIMEOUT\\\\n\")\n', '\t\tfmt.Fprint(conn, \"ERR-TIMEOUT\\\\n\")\n\t\t' + call + '\n', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
