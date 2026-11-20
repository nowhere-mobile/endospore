#!/usr/bin/env bash
# test-logoff-refusal-mediad.sh [--mutate] -- runs logoff_refusal_mediad_test.go (NWP-20261210-13: a sign-out whose media
# sweep did not verify keeps the session and kicks mediad once, after the re-arm). --mutate re-runs the tests against
# copies of main.go with the kick broken in turn, injected with `go test -overlay`, so the source tree is never edited;
# the placement test reads the same copy through NOWHERE_REFUSAL_MAIN_GO. Each mutant must be CONVICTED by a `--- FAIL`
# of the test named for it; one that does not apply, does not compile, or fails another test only counts as a failure.
# The control mutant changes only a comment's wording and must SURVIVE.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='LogoffRefusalKick'

out=$(go test -count=1 -run "$RUN_RE" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mkmut <copy> <old> <new> [<old2> <new2>]: writes main.go into <copy> with the FIRST exact match of each pair replaced.
mkmut() {
  python3 -I - main.go "$@" <<'PY'
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
s = open(src).read()
for k in range(0, len(pairs), 2):
    old, new = pairs[k], pairs[k + 1]
    if s.count(old) != 1:
        sys.exit(1)
    s = s.replace(old, new, 1)
open(dst, 'w').write(s)
PY
}
# runmut <label> <want test|-> <pairs...>: "-" is the control, which must pass every test.
runmut() {
  local label="$1" want="$2" m ov res rc
  shift 2
  m=$(mktemp -p "$W" mut.XXXX.go) && ov=$(mktemp -p "$W" ov.XXXX.json) || { echo "  INERT     $label -- no temp file"; fails=$((fails+1)); return; }
  if ! mkmut "$m" "$@"; then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/main.go" "$m" >"$ov"
  if ! res=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$res"; fails=$((fails+1)); return
  fi
  res=$(NOWHERE_REFUSAL_MAIN_GO="$m" go test -count=1 -overlay "$ov" -run "$RUN_RE" . 2>&1); rc=$?
  if [ "$want" = - ]; then
    if [ "$rc" -eq 0 ] && [[ "$res" != *'--- FAIL'* ]]; then echo "  survived  $label (control)"
    else echo "  KILLED    $label -- the control must pass"; tail -n 15 <<<"$res"; fails=$((fails+1)); fi
    return
  fi
  if ! score_mutant "$label" "$rc" "$res"; then fails=$((fails+1)); return; fi
  if [[ "$res" != *"--- FAIL: $want "* ]]; then
    echo "  WRONG-TEST $label -- $want did not fail"; fails=$((fails+1))
  fi
}
T=$'\t\t\t'
REARM="${T}rearmRoamSession(dest, name, pass, uid, seSecret, \"logout media sweep did not verify, re-arm\")"$'\n'
KICK="${T}logoffRefusalKickMediad(dest)"$'\n'
FAILED="${T}logoffSweepFailed(name, uid)"$'\n'
NOKEEP_RET="${T}	logoutEndNoKeep(dest, uid, \"media sweep did not verify\")"$'\n'"${T}	return"$'\n'
LANDED=$'\t\tdaySummaryForget(uid) //'
KEPT=TestLogoffRefusalKick_KeptSessionGetsMediaBack

# K1 is origin/main's behaviour with the hook kept: nothing gives the kept session its media back.
runmut "K1 the kick removed" "$KEPT" "$KICK" ''
runmut "K2 the kick moved above the re-arm" "$KEPT" "$KICK" '' "$REARM" "$KICK$REARM"
runmut "K3 the kick moved above logoffSweepFailed" "$KEPT" "$KICK" '' "$FAILED" "$KICK$FAILED"
runmut "K4 the kick called twice" "$KEPT" "$KICK" "$KICK$KICK"
runmut "K5 the kick moved into the noKeep block" TestLogoffRefusalKick_Placement \
  "$KICK" '' "$NOKEEP_RET" "${T}	logoutEndNoKeep(dest, uid, \"media sweep did not verify\")"$'\n'"${T}	logoffRefusalKickMediad(dest)"$'\n'"${T}	return"$'\n'
runmut "K6 a kick added after the seal lands" TestLogoffRefusalKick_LandedSignOutDoesNotKick \
  "$LANDED" $'\t\tlogoffRefusalKickMediad(dest)\n'"$LANDED"
runmut "C1 a comment's wording changed" - \
  "${T}// NWP-20261210-13: this logoff stopped mediad before its sweep" "${T}// NWP-20261210-13: the logoff stopped mediad before its sweep"
[ "$fails" -eq 0 ] && echo "== all mutations convicted, the control survived" || { echo "== $fails mutation(s) not scored as required"; exit 1; }
