#!/usr/bin/env bash
# test-chunk-pad.sh [--mutate] -- runs chunk_pad_test.go (NWP-20261124-22, h54 #2 slice a: the reader of padded
# chunks and manifests); --mutate re-runs it against unpackChunk (main.go) and unpadChunk (chunk_pad.go) with each
# rule broken in turn, restoring both files on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that
# fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap '[ -f "$W/main.go" ] && cp -f "$W/main.go" main.go; [ -f "$W/chunk_pad.go" ] && cp -f "$W/chunk_pad.go" chunk_pad.go; rm -rf "$W"' EXIT
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestChunkPad' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go"
cp chunk_pad.go "$W/chunk_pad.go"
cat >"$W/mut.py" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local res
  python3 "$W/mut.py" "$2" "$3" "$4" || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp -f "$W/$2" "$2"
}
mut "P1 version 3 skips unpadChunk" main.go \
  'case version >= chunkVersionPadded:\n\t\tp, err := unpadChunk\(b\)' \
  'case version >= chunkVersionPadded:
		p, err := b, error(nil)'
mut "P2 version 2 unpads first, strictly" main.go \
  'case version >= 2:\n\t\tout, err := decodeChunk\(b\)' \
  'case version >= 2:
		if p, perr := unpadChunk(b); perr != nil {
			return nil, perr
		} else {
			b = p
		}
		out, err := decodeChunk(b)'
mut "P3 the 0x80 requirement dropped" chunk_pad.go \
  'if i == 0 \|\| b\[i-1\] != chunkPadMarker \{(.*?)return b\[:i-1\], nil' \
  'if false {
		return nil, errChunkPadMarker
	}
	return b[:i], nil'
mut "P4 unpadChunk strips one 0x00 fewer" chunk_pad.go \
  '(for i > 0 && b\[i-1\] == 0x00 \{\n\t\ti--\n\t\})' \
  'for i > 0 && b[i-1] == 0x00 {
		i--
	}
	if i < len(b) {
		i++
	}'
mut "P5 the version-2 fallback removed" main.go \
  'if p, perr := unpadChunk\(b\); perr == nil \{' \
  'if p, perr := unpadChunk(b); false && perr == nil {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
