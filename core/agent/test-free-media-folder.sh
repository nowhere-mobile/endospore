#!/usr/bin/env bash
# test-free-media-folder.sh [--mutate] -- runs free_media_folder_test.go and the reap-list tests (NWP-20261207-14, h51
# #4: FREE-MEDIA-FOLDER frees one top-level folder's streamed copies and nothing else); --mutate re-runs them against
# copies of free_media_folder.go and reap_lists.go with each guard broken in turn, injected with `go test -overlay`, so
# the source tree is never edited. Each mutant must be CONVICTED by a `--- FAIL` of the test named beside it; one that
# does not apply, does not compile, or is convicted by no FAIL line or by another test only counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='TestFreeMediaFolder|TestReapLists'
RUN=(go test -count=1 -run "$PAT" -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <source file> <label> <test that must FAIL> <python-regex pattern> <replacement>
  local src="$1" label="$2" want="$3" m ov out
  m=$(mktemp -p "$W" mut.XXXXXX) || exit 2
  mv "$m" "$m.go"; m="$m.go"
  ov=$(mktemp -p "$W" overlay.XXXXXX) || exit 2
  python3 - "$src" "$m" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or n==s: sys.exit(1)
open(dst,'w').write(n)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run "$PAT" -v . 2>&1)
  if grep -q -- "--- FAIL: $want " <<<"$out"; then
    echo "  convicted $label by $want"
  elif grep -q -- '--- FAIL' <<<"$out"; then
    echo "  WRONG-TEST $label -- failed, but not $want: $(grep -o -- '--- FAIL: [A-Za-z0-9_/]*' <<<"$out" | sed 's/--- FAIL: //' | sort -u | tr '\n' ' ')"
    fails=$((fails+1))
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
S=free_media_folder.go
mut $S "G1 Ess rels listed" TestFreeMediaFolderKeys \
  '\tkeys := make\(\[\]string, 0, len\(seen\)\)' \
  '\tfor rel, r := range m.Ess {\n\t\tif mediaFolderOf(rel) == folder && r.E <= len(m.Chunks) {\n\t\t\tseen[cacheKey(deferredFile{Chunks: m.Chunks[r.S:r.E]})] = true\n\t\t}\n\t}\n\tkeys := make([]string, 0, len(seen))'
mut $S "G2 a prefix match without the '/' boundary" TestFreeMediaFolderKeys \
  'isMediaFolderRel\(rel\) && mediaFolderOf\(rel\) == folder' 'isMediaFolderRel(rel) && strings.HasPrefix(rel, folder)'
mut $S "G3 Android/ not excluded" TestFreeMediaFolderKeys \
  'if isMediaFolderRel\(rel\) && mediaFolderOf\(rel\) == folder' 'if mediaFolderOf(rel) == folder'
mut $S "G4 ERR-HEAD falls back to the all-cache freemedia" TestFreeMediaFolderRefusals \
  'if !ok \{\n\t\treply\("ERR-HEAD"\)' 'if !ok {\n\t\treply(strings.TrimSpace(triggerRoamWorker(dest, "freemedia", nm, "", uid, "", nil)))'
mut $S "G5 the list not removed" TestFreeMediaFolderHandler \
  '\tdefer os\.Remove\(p\)\n' ''
mut $S "G6 the folder in the log line" TestFreeMediaFolderLogNamesNoFolder \
  'free-media-folder: %d key\(s\) listed, reply %s\\n", n, tok\)' 'free-media-folder: folder %q, %d key(s) listed, reply %s\\\\n", folder, n, tok)'
mut $S "G7 '..' accepted" TestFreeMediaFolderValid \
  ' \|\| f == "\.\."' ''
mut reap_lists.go "G8 freemedia.keys dropped from isSessionCache" TestReapLists_L1_NoSessionRemovesTheLists \
  ', "freemedia\.keys"\}' '}'
mut $S "G9 the calls not serialized" TestFreeMediaFolderConcurrent \
  '\tfreeMediaFolderMu\.Lock\(\)\n\tdefer freeMediaFolderMu\.Unlock\(\)\n' '\t_ = &freeMediaFolderMu\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
