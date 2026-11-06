#!/usr/bin/env bash
# test-snapshot-release.sh [--mutate] -- runs snapshot_release_test.go (NWP-20261029-09: the strict release set, the
# blob cache eviction, the /release client); --mutate re-runs it against copies of snapshot_release.go with each
# guard broken in turn, injected with `go test -overlay`, so the source tree is never edited. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL line counts as
# a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=snapshot_release.go
PAT='SnapshotRelease|ManifestBlobsStrict|BlobCacheEvict|WorkerBlobCache|ReleaseBlobs|BlobCache'
RUN=(go test -count=1 -run "$PAT" .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local label="$1" m="$W/mut.go" ov="$W/overlay.json" out
  python3 - "$SRC" "$m" "$2" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(n)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$SRC" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run "$PAT" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "E1 manifestBlobsStrict swallows a fetch panic" 'err = errManifestUnreadable\n' '_ = errManifestUnreadable\n'
mut "E2 the keep set skips History" 'for _, h := range kept\.History \{(?=\n\t\t\tif err)' 'for _, h := range []headSnap{} {'
mut "E3 Deferred chunks ignored" 'for _, d := range m\.Deferred \{' 'for _, d := range map[string]deferredFile{} {'
mut "E4 the batch size is 4097" 'releaseBatchMax = 4096' 'releaseBatchMax = 4097'
mut "E5 blobCacheEvict leaves the in-memory set" 'delete\(blobCache, h\)' '_ = h'
mut "E6 a 404 treated as an error" 'if code == http\.StatusNotFound \|\| code == http\.StatusMethodNotAllowed \{' 'if false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
