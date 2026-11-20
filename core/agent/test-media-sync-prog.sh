#!/usr/bin/env bash
# test-media-sync-prog.sh [--mutate] -- runs the post-seal media sync progress tests (NWP-20261204-19); --mutate
# re-runs them with media_sync_prog.go, media_span.go, media_defer_sync.go or main.go broken in turn, restoring all
# four on exit. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts
# as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run '^TestMediaSyncProg_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

FILES=(media_sync_prog.go media_span.go media_defer_sync.go main.go)
W=$(mktemp -d) || exit 2
for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig" || exit 2; done
trap 'for f in "${FILES[@]}"; do cp -f "$W/$f.orig" "$f" 2>/dev/null; done; rm -rf "$W"' EXIT
fails=0
restore() { local f; for f in "${FILES[@]}"; do cp "$W/$f.orig" "$f"; done; }
# conv <label>: run the suite against the mutated files, then restore them.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: Test'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <file> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$2" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
mut "M1 no frame from fetchDeferredBytes (ADeferredArrivalWritesAFramePerChunk)" media_defer_sync.go '\n\t\tprog\.chunk\(\)\n' '\n'
mut "M2 no frame from fetchEssSpan (AnEssentialSpanWritesAFramePerChunk)" media_span.go '\n\t\tprog\.chunk\(\)\n' '\n'
mut "M3 the phase is not restored (ADeferredArrivalWritesAFramePerChunk: phase after)" media_sync_prog.go '\n\tsetProgPhase\(prev\)\n' '\n\t_ = prev\n'
mut "M4 the frame phase is save, not sizes (ADeferredArrivalWritesAFramePerChunk: phase)" media_sync_prog.go '\n\tsetProgPhase\("sizes"\)\n' '\n\tsetProgPhase("save")\n'
mut "M5 the seal's sync gets no prog (TheSyncOfASealWritesIt)" main.go 'arrivals, src, budget, prog\)' 'arrivals, src, budget, nil)'
mut "M6 one frame per file, not per chunk (ADeferredArrivalWritesAFramePerChunk: frame count)" media_defer_sync.go 'buf\.Write\(raw\)\n\t\tprog\.chunk\(\)\n\t\}' 'buf.Write(raw)\n\t}\n\tprog.chunk()'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
