#!/usr/bin/env bash
# test-auto-sweep-wall.sh [--mutate] -- runs the Auto sweep tests (NWP-20261127-05: the "ended after" figure is wall
# time from the first start of a hold, so a suspended stretch counts; the 2026-11-04 entry, NW-84c1d80f5001); --mutate
# re-runs them against copies of auto_sweep.go with each piece broken in turn, injected with `go test -overlay`, so the
# source tree is never edited. Each mutant must be CONVICTED by a `--- FAIL` of the test named for it; one that does not
# apply, does not compile, or fails another test only counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='AutoSweep|Sweep(Defer|Live)|GetSweep'

out=$(go test -count=1 -run "$RUN_RE" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <want test> <old> <new> [<old2> <new2>]: replaces the FIRST exact match of each pair in auto_sweep.go
  local label="$1" want="$2" src=auto_sweep.go m ov out rc
  shift 2
  m=$(mktemp -p "$W" mut.XXXX.go) && ov=$(mktemp -p "$W" ov.XXXX.json) || { echo "  INERT     $label -- no temp file"; fails=$((fails+1)); return; }
  python3 -I - "$src" "$m" "$@" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
s = open(src).read()
for k in range(0, len(pairs), 2):
    old, new = pairs[k], pairs[k + 1]
    if old not in s:
        sys.exit(1)
    s = s.replace(old, new, 1)
open(dst, 'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run "$RUN_RE" . 2>&1); rc=$?
  if ! score_mutant "$label" "$rc" "$out"; then fails=$((fails+1)); return; fi
  if [[ "$out" != *"--- FAIL: $want "* ]]; then
    echo "  WRONG-TEST $label -- $want did not fail"; fails=$((fails+1))
  fi
}
FRESH='			// NWP-20261127-05: the wall start, set only at a fresh hold; a joining sweep does not move it.
			autoSweepBeganWall = autoSweepWallNow()
'
mut "M1 held back on the monotonic clock" TestAutoSweepEndedAfterCountsTimeAsleep \
  'held = autoSweepWallNow().Sub(autoSweepBeganWall)' 'held = now.Sub(autoSweepBegan)'
mut "M2 the wall start set on every AUTO-SWEEP 1, joiners too" TestAutoSweepEndedAfterCountsFromTheFirstStart \
  "$FRESH" '' $'\t\tautoSweepRuns++\n' $'\t\tautoSweepBeganWall = autoSweepWallNow()\n\t\tautoSweepRuns++\n'
mut "M3 the wall start never reset at a fresh hold" TestAutoSweepEndedAfterALapsedLeaseStartsAgain \
  "$FRESH" $'\t\t\tif autoSweepBeganWall.IsZero() {\n\t\t\t\tautoSweepBeganWall = autoSweepWallNow()\n\t\t\t}\n'
mut "M4 no clamp on a clock set back" TestAutoSweepEndedAfterAClockSetBackIsZero \
  'if held < 0 {' 'if false {'
mut "M5 a stale wall start read after a session reset" TestAutoSweepLateEndAfterASessionResetLogsZero \
  '!autoSweepBegan.IsZero() && !autoSweepBeganWall.IsZero()' '!autoSweepBeganWall.IsZero()'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
