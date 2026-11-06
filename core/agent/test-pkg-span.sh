#!/usr/bin/env bash
# test-pkg-span.sh [--mutate] -- runs pkg_span_test.go and TestManifestWireNames (NWP-20261127-01: a bare vault or #de
# head carries `pspan`, per package the chunk ranges that hold only its data; a held package is its own group; the
# reader refuses a malformed or shared span; no other scope and no full-tar seal writes it). --mutate re-runs them
# against copies of incremental_seal.go / pkg_span.go / main.go with each guard broken in turn, injected with
# `go test -overlay`, so the source tree is never edited. Each mutant must be CONVICTED by a `--- FAIL` line of the
# test named for it; one that does not apply, does not compile, or fails without that line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='TestPkgSpan|TestManifestWireNames'

out=$(go test -count=1 -run "$PAT" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <required --- FAIL test> <python-regex pattern> <replacement> [<pattern> <replacement>]...
  local label="$1" src="$2" want="$3" m="$W/mut.go" ov="$W/overlay.json" out nl=$'\n'
  python3 - "$src" "$m" "${@:4}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst=sys.argv[1:3]
rest=sys.argv[3:]
s=open(src).read()
for pat,rep in zip(rest[0::2],rest[1::2]):
    s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run "$PAT" . 2>&1)
  if [[ "$nl$out" == *"$nl"*"--- FAIL: $want "* ]]; then
    echo "  convicted $label: --- FAIL: $want"
  elif [[ "$nl$out" == *"$nl"*'--- FAIL'* ]]; then
    echo "  WRONG-FAIL $label -- failed, but not in $want:"; grep -- '--- FAIL' <<<"$out"; fails=$((fails+1))
  elif [[ "$nl$out" != *"${nl}ok"* ]]; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; tail -15 <<<"$out"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "M1 the hold unit rule removed" incremental_seal.go TestPkgSpan_VaultEachPackageRestoresAlone \
  'if hp := chooserPkg \+ "/" \+ odHoldDirName \+ "/"; strings\.HasPrefix\(r, hp\)' \
  'if hp := chooserPkg + "/" + odHoldDirName + "/"; false && strings.HasPrefix(r, hp)'
mut "M2 mixed ignored (both sites)" incremental_seal.go TestPkgSpan_MixedGroupLeavesItsPackageOut \
  'groupMixed = true // loose root entries opened' 'groupMixed = false // loose root entries opened' \
  'groupMixed = true // a loose root entry joins' 'groupMixed = false // a loose root entry joins'
mut "M2b mixed ignored when loose root entries open the group" incremental_seal.go TestPkgSpan_MixedGroupLeavesItsPackageOut \
  'groupMixed = true // loose root entries opened' 'groupMixed = false // loose root entries opened'
mut "M3 the reader's bounds check removed" pkg_span.go TestPkgSpan_ReaderRefusesMalformed \
  'if r\[0\] < 0 \|\| r\[0\] >= r\[1\] \|\| r\[1\] > len\(m\.Chunks\) \{' 'if false {'
mut "M4 the reader's touch/overlap check removed" pkg_span.go TestPkgSpan_ReaderRefusesMalformed \
  'if i > 0 && r\[0\] <= rs\[i-1\]\[1\] \{' 'if false && i > 0 {'
mut "M5 the reader's Deferred-under-pkg check removed" pkg_span.go TestPkgSpan_ReaderRefusesMalformed \
  'if attrPkgForRel\(rel\) == pkg \{' 'if false && attrPkgForRel(rel) == pkg {'
mut "M6 the scope gate removed" main.go TestPkgSpan_MediaAndFullSealWriteNone/media \
  'if incrementalSeal\(\) && \(strings\.IndexByte\(profile, .#.\) < 0 \|\| strings\.HasSuffix\(profile, "#de"\)\) \{\n\t\tpkgSpans =' \
  $'if true {\n\t\tpkgSpans ='
mut "M7 the cross-claim exclusion removed" pkg_span.go TestPkgSpan_BuildLeavesOutSharedAndBadIndices \
  'bad\[o\], bad\[pkg\] = true, true' '_ = o'
mut "M8 a mixed group no longer leaves its package out whole" pkg_span.go TestPkgSpan_MixedGroupLeavesWholePackageOut \
  'if up := spanPkgOfUnit\(g\.unit\); up != "" \{\n\t\t\t\tbad\[up\] = true\n\t\t\t\}\n\t\t\tfor w := range g\.weights \{\n\t\t\t\tbad\[w\] = true\n\t\t\t\}' \
  ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
