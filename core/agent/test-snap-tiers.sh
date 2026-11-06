#!/usr/bin/env bash
# test-snap-tiers.sh [--mutate] -- the automatic snapshots keep 1 recent + 1 hourly + 5 daily, a slot reserved per
# tier, capped at 7, so "Restore a snapshot" reaches days back under a seal every two minutes (docs/product-decisions.md
# 2026-11-02 #1, NWP-20261124-02). Plain: the SnapTiers tests plus the existing retention, snapshot, delete and rollback
# tests. --mutate applies each mutant to main.go in place (a pristine copy lives in one temp root, restored after every
# mutant and on exit) and runs the SnapTiers tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails
# to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestSnapTiers|TestPruneSnapshots|TestSnapshot|TestDeleteSnapshot|TestRollbackHead' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <mutator> <convicting test>... -- <mutator> is a python3 program run with the file's text in `s`,
# leaving the mutated text in `s`; it exits 1 when its anchor is not found exactly once.
mut() {
  local label="$1" file="$2" prog="$3" res want
  shift 3
  python3 -c "
import sys
p = sys.argv[1]
s = open(p).read()
$prog
open(p, 'w').write(s)
" "$file" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
  res=$(go test -count=1 -run 'TestSnapTiers' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
# M1: the hourly tier keeps its NEWEST candidate, so nothing ages out into the daily tier.
M1='
old = "range hourly[len(hourly)-hs:] {"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "range hourly[:hs] {")
'
# M2: the automatic cap default back to 5.
M2='
old = "snapEnv(\"NOWHERE_SNAP_AUTO\", 7)"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "snapEnv(\"NOWHERE_SNAP_AUTO\", 5)")
'
# M3: the recent default back to 2.
M3='
old = "snapEnv(\"NOWHERE_SNAP_AUTO_RECENT\", 1)"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "snapEnv(\"NOWHERE_SNAP_AUTO_RECENT\", 2)")
'
# M4: no day bucket, so two daily entries from one day stay.
M4='
old = "\t\t\tb := s.Time / 86400\n"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "\t\t\tb := int64(i)\n")
'
# M5 (RF-001): the expiry check moved after the recent tier, so an expired newest entry stays.
M5='
old = "\t\tif s.Time > 0 \u0026\u0026 age > dayWin { // older than the day window -> drop, in every tier (the recent one too)\n\t\t\tcontinue\n\t\t}\n"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "\t\tif age > dayWin \u0026\u0026 recent >= rs {\n\t\t\tcontinue\n\t\t}\n")
'
mut "M1 the hourly tier keeps its newest candidate" main.go "$M1" TestSnapTiersThirtyDaysOfTwoMinuteSeals TestSnapTiersGapAndSparseSeals
mut "M2 the automatic cap default back to 5" main.go "$M2" TestSnapTiersThirtyDaysOfTwoMinuteSeals
mut "M3 the recent default back to 2" main.go "$M3" TestSnapTiersThirtyDaysOfTwoMinuteSeals
mut "M4 the day-bucket check removed" main.go "$M4" TestSnapTiersThirtyDaysOfTwoMinuteSeals TestSnapTiersGapAndSparseSeals
mut "M5 the recent tier keeps an expired newest entry" main.go "$M5" TestSnapTiersExpiredNewestDrops
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
