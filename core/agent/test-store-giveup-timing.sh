#!/usr/bin/env bash
# test-store-giveup-timing.sh [--mutate] -- runs store_giveup_timing_test.go (NWP-20261112-17): in cap mode, on the
# real clock, the `restore` verb (re-executed through main() with NOWHERE_STORE_GIVEUP=1) and a real DELETE against a
# store that never answers stop within 15 s plus one read and print the stop line, and against a store that comes
# back inside the window both succeed. The four cases take about a minute.
# --mutate re-runs them against pristine copies of main.go and store_giveup.go with each arm or window broken in turn,
# restoring them on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply, or fails to
# compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
FILES=(main.go store_giveup.go)
RUN=(go test -count=1 -run 'TestStoreGiveUpTiming_' .)
W=$(mktemp -d) || exit 2
restore() {
  local f
  for f in "${FILES[@]}"; do
    [ -f "$W/$(basename "$f").orig" ] && cp -f "$W/$(basename "$f").orig" "$f"
  done
  return 0
}
trap 'restore; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$(basename "$f").orig"; done
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local res rc
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
  restore
}
mut "T1 handleDelete's arm removed" main.go '\tdefer armStoreGiveUp\("delete"\)\(\)[^\n]*\n' ''
mut "T2 main()'s NOWHERE_STORE_GIVEUP arm removed" main.go '\tif os\.Getenv\("NOWHERE_STORE_GIVEUP"\) == "1" \{\n\t\tdefer armStoreGiveUp\("sign-in restore"\)\(\)\n\t\}\n' ''
mut "T3 storeGiveUpWindow 15 s -> 60 s" store_giveup.go 'const storeGiveUpWindow = 15 \* time\.Second' 'const storeGiveUpWindow = 60 * time.Second'
mut "T4 storeGiveUpWindow 15 s -> 5 s" store_giveup.go 'const storeGiveUpWindow = 15 \* time\.Second' 'const storeGiveUpWindow = 5 * time.Second'
mut "T5 storeGivenUp returns false" store_giveup.go 'return storeGiveUp\.armed > 0 && ' 'return false && storeGiveUp.armed > 0 && '
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
