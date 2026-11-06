#!/usr/bin/env bash
# test-restore-cap-prefetch.sh [--mutate] -- NWP-20261128-21: cdcRestore's launcher and healDeferred ask for their read
# caps a batch ahead of the chunks that use them (restoreCapBatch keys per call), after the first progress frame, and a
# failed batch stops the asking. Runs the focused Go tests; --mutate applies each mutant to pristine copies of main.go
# and media_heal.go (both restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does
# not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp media_heal.go "$W/media_heal.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/media_heal.go.orig" media_heal.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestCdcRestoreRequestsCapsABatchAhead|TestCdcRestoreStopsAskingAfterAFailedBatch|TestHealAsksForCapsABatchAhead'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
pristine() {
  cp "$W/main.go.orig" main.go
  cp "$W/media_heal.go.orig" media_heal.go
}
# mutate <label> <file> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" body="$3" o
  pristine
  if ! python3 -c "
import sys
f = sys.argv[1]
s = open(f).read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)" "$f"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); pristine; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  pristine
}
echo "== mutations =="
mutate "M1: cdcRestore requests every batch before the launcher starts" main.go "
t = s.replace('\task := restoreCapPrefetchOn()\n', '\task := restoreCapPrefetchOn()\n\tfor j := 0; ask && j < total; j += restoreCapBatch {\n\t\te := min(j+restoreCapBatch, total)\n\t\tks := make([]string, 0, e-j)\n\t\tfor _, c := range m.Chunks[j:e] {\n\t\t\tks = append(ks, \"blob/\"+c)\n\t\t}\n\t\task = restoreCapPrefetch(ks)\n\t}\n\task = false\n', 1)"
mutate "M2: a false return does not stop cdcRestore asking" main.go "
t = s.replace('ask = restoreCapPrefetch(keys)', '_ = restoreCapPrefetch(keys)', 1)"
mutate "M3: the launcher's batch keys start at i+1" main.go "
t = s.replace('m.Chunks[i:end]', 'm.Chunks[i+1:end]', 1)"
mutate "M4: healDeferred requests every batch before its loop" media_heal.go "
t = s.replace('\task := restoreCapPrefetchOn()\n', '\task := restoreCapPrefetchOn()\n\tfor ask && asked < len(plan) {\n\t\tn := min(asked+restoreCapBatch, len(plan))\n\t\task = restoreCapPrefetch(plan[asked:n])\n\t\tasked = n\n\t}\n', 1)"
mutate "M5: healDeferred makes one call per file" media_heal.go "
t = s.replace('n := min(asked+restoreCapBatch, len(plan))', 'n := planEnd[rel]', 1)"
mutate "M6: healDeferred's early writeProg(0, int(total)) is deleted" media_heal.go "
t = s.replace('\twriteProg(0, int(total))\n', '', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "6 mutants convicted"
