#!/usr/bin/env bash
# test-media-evict-keep.sh [--mutate] -- NWP-20261110-04: mediad's evictCache never deletes the cache entry its caller
# has just landed (fetchFile, ensureRange's promotion). --mutate applies each mutant to a pristine copy of
# media_server.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or does not
# compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp media_server.go "$W/ms.orig" || exit 2
trap 'cp "$W/ms.orig" media_server.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestEvictKeep|TestEvictCache|TestMediaLogLinesQuotePaths|TestEveryGoroutineGoesThroughGoSafe"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new>: replace the first <old> in a pristine media_server.go, require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" res
  cp "$W/ms.orig" media_server.go
  if ! OLD="$old" NEW="$new" python3 -c "
import os
s = open('media_server.go').read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open('media_server.go','w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "TestEvictKeep" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "M1 the keep skip removed" 'if p == keep {' 'if false {'
mutate "M2 fetchFile passes the empty keep" 's.evictCache(cp) // #84 P5: bound the cache after adding a whole file' 's.evictCache("") // #84 P5: bound the cache after adding a whole file'
mutate "M3 ensureRange passes the empty keep" 's.evictCache(cp) // #84 P5: a whole file just completed' 's.evictCache("") // #84 P5: a whole file just completed'
mutate "M4 keep compared by base name" 'if p == keep {' 'if filepath.Base(p) == filepath.Base(keep) {'
cp "$W/ms.orig" media_server.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
