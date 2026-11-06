#!/usr/bin/env bash
# test-storage-count.sh [--mutate] -- runs storage_count_test.go (NWP-20261118-06, h48 #6): the storage walk beats the
# RO lane's stall watchdog through $NOWHERE_PROGRESS, one count runs at a time, its result is kept in RAM and served
# with its age, a failed refresh keeps the old figure, a reset drops it (and a count begun before the reset publishes
# nothing), and GET-STORAGE-BREAKDOWN joins the running count. --mutate re-runs the tests with each rule broken in
# turn and restores the files on exit. A mutant is CONVICTED only by a failing test (`--- FAIL`); one that does not
# apply, or that breaks the build, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(storage_breakdown.go storage_count.go main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f.orig" ] && cp "$W/$f.orig" "$f"; done; rm -rf "$W"; }
trap restore EXIT
RUN=(go test -count=1 -run 'TestStorageCount' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local res mrc
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  cp "$W/$2.orig" "$2"
}
SB=storage_breakdown.go; SC=storage_count.go
mut "M1 the walk writes no progress beat" $SB \
  '\n\t\t\tstorageWalkBeat\(storageWalkFiles\)' ''
mut "M2 START ignores a running count (two counts)" $SC \
  'if storageCount\.running \{' 'if false {'
mut "M3 forgetSessionKeys keeps the storage count" main.go \
  '(func forgetSessionKeys\(why string\) \{\n\tderiveKeyForget\(\)\n\tfmt\.Fprintf[^\n]*\n)\tresetStorageCount\(\)[^\n]*\n' '\1'
mut "M4 a count publishes without the gen check" $SC \
  'if storageCount\.gen != gen \{' 'if false && storageCount.gen != gen {'
mut "M5 a failed refresh clears the old figure" $SC \
  '(storageCount\.lastErr = storageCountToken\(out\)\n)' '\1\t\t\t\tstorageCount.json = ""\n'
mut "M6 GET-STORAGE-BREAKDOWN makes its own worker call instead of joining" $SB \
  'j, started := startStorageCount\(dest\)' 'j, started := &storageCountJob{done: make(chan struct{}), out: storageCountRun(dest)}, true\n\tclose(j.done)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
