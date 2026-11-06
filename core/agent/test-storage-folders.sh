#!/usr/bin/env bash
# test-storage-folders.sh [--mutate] -- runs storage_folders_test.go (NWP-20261123-14, h51 #4 A1): the storage
# breakdown names each top-level folder of the media root, plus one row for the files outside them, and the rows sum
# to media_bytes; the #media head's per-file index (Ess, EssIdx) and its Deferred entries price each folder, an
# Android/ rel counts in no folder, and one bad span makes the answer not measured; the folder total joins the
# attributed sum, so apps + folders + store_other is the plan total; a dotted folder ("Movies.2024") is a folder row
# and never an app row; the folders are measured without a Pkg index, and StoreMeasured still means one. --mutate
# re-runs the tests against storage_breakdown.go with each rule broken in turn and restores it on exit. A mutant is
# CONVICTED only by a failing test (`--- FAIL`); one that does not apply, or that breaks the build, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(storage_breakdown.go)
restore() {
  local f
  for f in "${FILES[@]}"; do
    if [ -f "$W/$f.orig" ]; then cp "$W/$f.orig" "$f"; fi
  done
  rm -rf "$W"
}
trap restore EXIT
RUN=(go test -count=1 -run 'TestStorageFolders|TestMediaFolderStore|TestWithStoreBytesFolders' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  cp "$W/$2.orig" "$2"
}
SB=storage_breakdown.go
mut "F1 the files-outside-folders row dropped" $SB \
  '\tfolders\[name\] \+= n\n' '\tif name != "" {\n\t\tfolders[name] += n\n\t}\n'
mut "F2 an Android rel counted into a folder" $SB \
  'return !strings\.HasPrefix\(rel, "Android/"\)' 'return true'
mut "F3 EssIdx ignored" $SB \
  '!m\.EssIdx \|\| ' ''
mut "F4 the folder total left out of attributed" $SB \
  '(for _, v := range fstore \{\s*)attributed \+= v' '\1_ = v'
mut "F5 the dotted-folder Pkg skip dropped" $SB \
  'if folderKeys\[pkg\] \{' 'if false && folderKeys[pkg] {'
mut "F6 the #media Deferred folder skip dropped" $SB \
  'isMedia && isMediaFolderRel\(rel\)' 'false'
mut "F7 a bad span skips its rel instead of refusing the answer" $SB \
  '(r\.S > r\.E \{\s*)return nil, false' '\1continue'
mut "F8 an overlaid folder's real files sent to the files-outside-folders row" $SB \
  'addFolderBytes\(folders, media, underFolder\(external, full != "", full\), n\)' 'addFolderBytes(folders, media, "", n)'
mut "F9 the folders measured only when the packages are" $SB \
  'if !measured && !foldersMeasured \{' 'if !measured {'
mut "F10 StoreMeasured set by the folders alone" $SB \
  'b\.StoreMeasured = measured' 'b.StoreMeasured = true'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
