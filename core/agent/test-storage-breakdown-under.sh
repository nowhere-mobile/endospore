#!/usr/bin/env bash
# test-storage-breakdown-under.sh [--mutate] -- runs storage_breakdown_under_test.go and the breakdown's other tests
# (NWP-20261016-49): a media fetch cache's `.under` binds hold the user's REAL files, so the breakdown counts them on
# the app row or in MediaBytes, never in CacheBytes, and TotalBytes is unchanged; a sparse `.part` counts by the disk
# it holds; a cache dir or `.under` that cannot be listed counts as Blind. --mutate re-runs the tests against
# storage_breakdown.go / media_seal.go with each rule broken in turn, restoring both files on exit. A mutant is
# CONVICTED only by a failing test (`--- FAIL`); one that does not apply, or that breaks the build, is a failure.
# Run it as a user other than root: two of the Blind cases need directory permissions to bite, and skip as root.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestUnderRel|TestUnderOwner|TestStorageBreakdown|TestUnderLeaf|TestDirBytes|TestAddPkgDirs|TestCollectStorageBreakdown' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

FILES=(storage_breakdown.go media_seal.go)
for f in "${FILES[@]}"; do cp "$f" "$f.orig"; done
trap 'for f in "${FILES[@]}"; do mv -f "$f.orig" "$f"; done' EXIT
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
  cp "$2.orig" "$2"
}
SB=storage_breakdown.go; MS=media_seal.go
mut "U1 the old loop: the whole cache dir, .under included, in CacheBytes" $SB \
  'out\.CacheBytes \+= cacheBytesExceptUnder\(c\.dir, mst\)\n\t\taddUnderBytes\(perPkg, folders, &out\.MediaBytes, filepath\.Join\(c\.dir, "\.under"\), c\.external, mst\)' \
  'out.CacheBytes += dirBytes(c.dir, mst)'
mut "U2 .under excluded from the cache but counted nowhere" $SB \
  '\n\t\taddUnderBytes\(perPkg, folders, &out\.MediaBytes, filepath\.Join\(c\.dir, "\.under"\), c\.external, mst\)' ''
mut "U3 cacheBytesExceptUnder no longer skips .under" $SB \
  'if e\.Name\(\) == "\.under" \{\n\t\t\tcontinue' 'if false {\n\t\t\tcontinue'
mut "U4 underOwner never names an app" $SB \
  'if external && !strings\.HasPrefix\(rel, "Android/"\) \{' 'if true {'
mut "U5 a dotted media-root folder read as a package" $SB \
  'if external && !strings\.HasPrefix\(rel, "Android/"\) \{' 'if false && !strings.HasPrefix(rel, "Android/") {'
mut "U6 a hashed leaf's bytes dropped" $SB \
  'owner := ""\n' 'owner := ""\n\t\t\tif !ok {\n\t\t\t\treturn\n\t\t\t}\n'
mut "U7 underRel decodes _s as _" $MS \
  "case 's':\n\t\t\tb\.WriteByte\('/'\)" "case 's':\n\t\t\tb.WriteByte('_')"
mut "U8 underRel accepts the hashed form" $MS \
  "b\.WriteByte\('/'\)\n\t\tdefault:\n\t\t\treturn \"\", false" "b.WriteByte('/')\n\t\tdefault:\n\t\t\tb.WriteByte(leaf[i])"
mut "U9 a file owned by its leaf's rel, not its own path" $SB \
  'path\.Join\(rel, filepath\.ToSlash\(in\)\)' 'path.Join(rel, path.Base(filepath.ToSlash(in)))'
mut "U10 the CE cache's rels read as media-root rels" $SB \
  '\{filepath\.Join\(userRoot, chooserPkg, "files", "\.nowhere-media"\), false\}' '{filepath.Join(userRoot, chooserPkg, "files", ".nowhere-media"), true}'
mut "U11 the -ext cache dropped from the walk" $SB \
  '\n\t\t\{filepath\.Join\(userRoot, chooserPkg, "files", "\.nowhere-media-ext"\), true\},' ''
mut "U12 a hashed leaf's inner path read as if the leaf were readable" $SB \
  'ok && err == nil' '(ok || true) && err == nil'
mut "U13 an unlistable cache dir is not counted as blind" $SB \
  '(func cacheBytesExceptUnder.*?)st\.blind\+\+' '\1_ = st'
mut "U14 an unlistable .under is not counted as blind" $SB \
  '(func addUnderBytes.*?)st\.blind\+\+' '\1_ = st'
mut "U15 a .part counted at its apparent size" $SB \
  'if !strings\.HasSuffix\(fi\.Name\(\), "\.part"\) \{' 'if true {'
mut "U16 a .part counted at its blocks, uncapped by its size" $SB \
  'if a := int64\(sys\.Blocks\) \* 512; a < n \{' 'if a := int64(sys.Blocks) * 512; true {'
mut "U17 the cache summed by apparent size again (cacheFileBytes bypassed)" $SB \
  'total \+= cacheFileBytes\(fi\)' 'total += fi.Size()'
mut "U18 the chooser's own external data/obb billed to a chooser row" $SB \
  '\tif pkg == chooserPkg && \(strings\.HasPrefix\(rel, "Android/data/"\) \|\| strings\.HasPrefix\(rel, "Android/obb/"\)\) \{\n\t\treturn ""\n\t\}\n' ''
mut "U19 the chooser's Android/media dropped too, unlike the real-path walk" $SB \
  '\(strings\.HasPrefix\(rel, "Android/data/"\) \|\| strings\.HasPrefix\(rel, "Android/obb/"\)\)' 'strings.HasPrefix(rel, "Android/")'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
