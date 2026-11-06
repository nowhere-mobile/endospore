#!/usr/bin/env bash
# test-media-append-seed.sh [--mutate] -- an append to an on-demand media file keeps its bytes (NWP-20261109-01):
# writeOpenSeeds (no FUSE) and a real-FUSE append through the overlay. --mutate applies each mutant in place (a
# pristine copy lives in one temp root, restored after every mutant and on exit) and runs the same tests; each must be
# CONVICTED by a real `--- FAIL`. A mutant that fails to apply or to compile counts as a failure, and so does one the
# run could not judge: M2 is convicted only by the FUSE test, so on a host with no usable FUSE it is NOT CONVICTED.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(mediafs.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN='TestWriteOpenSeeds|TestOverlayAppend'

out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want
  shift 4
  python3 - "$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -v -run "$RUN" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      elif [[ "$res" == *"--- SKIP: $want"* ]]; then echo "  NOT CONVICTED $label -- $want skipped (no usable FUSE here)"; fails=$((fails+1))
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "M1 writeOpenSeeds drops the O_APPEND arm" mediafs.go 'flags&syscall.O_ACCMODE == syscall.O_RDWR || flags&syscall.O_APPEND != 0' 'flags&syscall.O_ACCMODE == syscall.O_RDWR' TestWriteOpenSeeds
mut "M2 openForWrite back to the inline RDWR-only condition" mediafs.go 'if writeOpenSeeds(flags) {' 'if flags&syscall.O_ACCMODE == syscall.O_RDWR && flags&syscall.O_TRUNC == 0 {' TestOverlayAppendKeepsDeferredBytes
mut "M3 writeOpenSeeds ignores O_TRUNC" mediafs.go 'if flags&syscall.O_TRUNC != 0 {' 'if false {' TestWriteOpenSeeds
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
