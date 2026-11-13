#!/usr/bin/env bash
# test-save-mode.sh [--mutate] -- runs the save-mode tests (NWP-20261201-03: each profile chooses when its periodic saves
# run; the decision is docs/product-decisions.md, 2026-11-07); --mutate re-runs them against copies of the source with
# each piece broken in turn, injected with `go test -overlay`, so the source tree is never edited. Each mutant must be
# CONVICTED by a `--- FAIL` of the test named for it; one that does not apply, does not compile, or fails another test
# only counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestSaveMode|TestGateOnly|TestConcurrentSafeCmd|TestGatePoll' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <want test> <file> <old> <new>: replaces the one exact match of old in file
  local label="$1" want="$2" src="$3" m ov out rc
  m=$(mktemp -p "$W" mut.XXXX.go) && ov=$(mktemp -p "$W" ov.XXXX.json) || { echo "  INERT     $label -- no temp file"; fails=$((fails+1)); return; }
  python3 -I - "$src" "$m" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    sys.exit(1)
open(dst, 'w').write(s.replace(old, new, 1))
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  out=$(go test -count=1 -overlay "$ov" -run '^TestSaveMode' . 2>&1); rc=$?
  if ! score_mutant "$label" "$rc" "$out"; then fails=$((fails+1)); return; fi
  if [[ "$out" != *"--- FAIL: $want "* ]]; then
    echo "  WRONG-TEST $label -- $want did not fail"; fails=$((fails+1))
  fi
}
HELD=$'\t\t\tif saveHoldUpkeepAllowed() {\n\t\t\t\tkickMediad(dest)\n\t\t\t\tmaybePayRent(dest, name, pass, wgen)\n\t\t\t}\n'

mut "S1 Off not held" TestSaveModeDecisionTable save_mode.go \
  $'\tcase saveModeOff:\n\t\treturn saveHoldOff\n' $'\tcase saveModeOff:\n\t\treturn ""\n'
mut "S2 Wi-Fi held on a fresh UNMETERED" TestSaveModeDecisionTable save_mode.go \
  '!unmetered || netAt.IsZero()' 'unmetered || netAt.IsZero()'
mut "S3 a stale UNMETERED counted unmetered" TestSaveModeDecisionTable save_mode.go \
  'age < 0 || age > saveNetFresh' 'age < 0'
mut "S4 the mode consulted in syncDeferReason (manual held in Off)" TestSaveModeManualPathNeverHeld main.go \
  $'func syncDeferReason(now time.Time, sealBusy bool, odWin, loginWin time.Time, userWaiting int32) string {\n' \
  $'func syncDeferReason(now time.Time, sealBusy bool, odWin, loginWin time.Time, userWaiting int32) string {\n\tif saveModeValue == saveModeOff {\n\t\treturn saveHoldOff\n\t}\n'
mut "S5 sealDeferCount counted" TestSaveModeSyncLoopHold main.go \
  "$HELD" "$HELD"$'\t\t\tsealDeferCount.Add(1)\n'
mut "S6 reset not forgetting" TestSaveModeResetForgets od_window.go \
  $'\tsaveModeValue, saveNetUnmetered, saveNetAt = "", false, time.Time{}\n' ''
mut "S7 a hold skips the lease renewal" TestSaveModeSyncLoopHold main.go \
  "$HELD" $'\t\t\tif saveHoldUpkeepAllowed() {\n\t\t\t\tkickMediad(dest)\n\t\t\t}\n'
mut "S8 a hold skips the mediad revival" TestSaveModeSyncLoopHold main.go \
  "$HELD" $'\t\t\tif saveHoldUpkeepAllowed() {\n\t\t\t\tmaybePayRent(dest, name, pass, wgen)\n\t\t\t}\n'
mut "S9 the report's age on the monotonic clock" TestSaveModeNetTimeIsWallClock save_mode.go \
  'unmetered, time.Now().Round(0)' 'unmetered, time.Now()'
mut "S10 a report from the future counted fresh" TestSaveModeDecisionTable save_mode.go \
  'age < 0 || age > saveNetFresh' 'age > saveNetFresh'
mut "S11 the hold logged every cycle" TestSaveModeHoldLogStep save_mode.go \
  'if reason == prev {' 'if false {'
mut "S12 the hold runs the upkeep during a DELETE" TestSaveModeSyncLoopHoldStandsAsideForADelete main.go \
  'if saveHoldUpkeepAllowed() {' 'if true {'
mut "S13 the refresh dropped from syncLoop" TestSaveModeSyncLoopHold main.go \
  $'\t\trefreshSaveMode(dest, uid)\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
