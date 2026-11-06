#!/usr/bin/env bash
# test-roamin-busy-name.sh [--mutate] -- NWP-20261029-03: a busy (ERR-WORKER-BUSY) or timed-out (ERR-TIMEOUT) sign-in logs
# the uid, never the typed profile name, because no scrub follows either reply. Runs the focused Go tests; --mutate applies
# each mutant to a pristine copy of main.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not
# apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="RoamInBusy|FailedSigninScrub"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" body="$2" o
  cp "$W/main.go.orig" main.go
  if ! python3 -c "
s = open('main.go').read(); t = s
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
BUSY='roam-in user %s: the worker lane is busy'
TMO='roam-in user %s: the worker timed out'
mutate "N1: the busy line prints %q of name again" "
t = s.replace('$BUSY', 'roam-in %q: the worker lane is busy', 1).replace('nothing was attempted\\\\n\", uid)', 'nothing was attempted\\\\n\", name)', 1)"
mutate "N2: the timeout line prints name" "
t = s.replace('$TMO', 'roam-in %q: the worker timed out', 1).replace('not a credential verdict\\\\n\", uid)', 'not a credential verdict\\\\n\", name)', 1)"
mutate "N3: the busy line prints the name with %s" "
t = s.replace('nothing was attempted\\\\n\", uid)', 'nothing was attempted\\\\n\", name)', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
