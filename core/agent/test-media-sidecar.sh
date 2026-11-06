#!/usr/bin/env bash
# test-media-sidecar.sh [--mutate] -- NWP-20261112-23: mediad's initPart repairs a full-size .part whose .have sidecar
# is missing or short, so its marks are kept and the file promotes; a repair that cannot be written still serves.
# --mutate applies each mutant to a pristine copy of media_server.go (restored on exit) and requires a real
# `--- FAIL`: a mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp media_server.go "$W/ms.orig" || exit 2
trap 'cp "$W/ms.orig" media_server.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestMediaSidecar|TestRange|TestCorruptChunkFailsFast|TestPrefetchSkipsDamaged|TestEvictKeep|TestMediaLogLinesQuotePaths|TestEveryGoroutineGoesThroughGoSafe|TestNoLogPrintsAProfileNameOutsideQuotes"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new>: replace the first <old> in a pristine media_server.go, require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" res rc
  cp "$W/ms.orig" media_server.go
  if ! OLD="$old" NEW="$new" python3 -c "
import os
s = open('media_server.go').read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open('media_server.go','w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "TestMediaSidecar" . 2>&1); rc=$?
  score_mutant "$lbl" "$rc" "$res" || FAILS=$((FAILS+1))
}
mutate "M1 the early return on size alone" 'if have, herr := os.ReadFile(hp); herr == nil && len(have) == len(d.Chunks) {' 'if _, herr := os.ReadFile(hp); true || herr == nil {'
mutate "M2 any non-empty sidecar accepted" 'herr == nil && len(have) == len(d.Chunks)' 'herr == nil && len(have) > 0'
mutate "M3 a valid sidecar re-zeroed" 'herr == nil && len(have) == len(d.Chunks)' 'false && herr == nil && len(have) == len(d.Chunks)'
mutate "M4 the repair's write error returned" 'dlog("mediad: .have repair' 'return err; dlog("mediad: .have repair'
cp "$W/ms.orig" media_server.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
