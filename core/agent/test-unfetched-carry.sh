#!/usr/bin/env bash
# test-unfetched-carry.sh [--mutate] -- runs unfetched_carry_test.go and unfetched_guard_test.go (NWP-20261129-03: a bare
# vault or #de seal re-emits by hash, before the tar footer, each listed unfetched package the walk did not see whose
# stored span the reader trusts; an untrusted span is still refused). --mutate breaks a COPY of the package in the
# suite's temp root, one guard at a time, so the source tree is never edited. Each mutant must be CONVICTED by a
# `--- FAIL` line of the test named for it; one that does not apply, does not compile, or fails without that line counts
# as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='TestUnfetchedCarry|TestUnfetchedGuard'

out=$(go test -count=1 -run "$PAT" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

mkdir "$W/pkg" "$W/tmp" || exit 2
cp -a . "$W/pkg/" || exit 2
export TMPDIR="$W/tmp" GOTMPDIR="$W/tmp"
SRC=$PWD
cd "$W/pkg" || exit 2

fails=0
mut() { # mut <label> <file> <required --- FAIL test> <python-regex pattern> <replacement> [<pattern> <replacement>]...
  local label="$1" src="$2" want="$3" out nl=$'\n'
  python3 - "$src" "${@:4}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp "$SRC/$src" "$src"; return; }
import re,sys
src=sys.argv[1]
rest=sys.argv[2:]
s=open(src).read()
for pat,rep in zip(rest[0::2],rest[1::2]):
    s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(src,'w').write(s)
PY
  if ! out=$(go vet . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); cp "$SRC/$src" "$src"; return
  fi
  out=$(go test -count=1 -run "$PAT" . 2>&1)
  if [[ "$nl$out" == *"$nl"*"--- FAIL: $want "* ]]; then
    echo "  convicted $label: --- FAIL: $want"
  elif [[ "$nl$out" == *"$nl"*'--- FAIL'* ]]; then
    echo "  WRONG-FAIL $label -- failed, but not in $want:"; grep -- '--- FAIL' <<<"$out"; fails=$((fails+1))
  elif [[ "$nl$out" != *"${nl}ok"* ]]; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; tail -15 <<<"$out"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
  cp "$SRC/$src" "$src"
}
mut "C1 the call removed" main.go TestUnfetchedCarry_U1_VaultCarriesByteIdentical \
  'chunks, unfSpans, unfPkg, unfN := sealCarryUnfetched\(profile, oldM, chunks, acct, deferredMap\)' \
  'var unfSpans map[string][][2]int; var unfPkg map[string]int64; unfN := 0'
mut "C2 the chunks appended after the footer" unfetched_carry.go TestUnfetchedCarry_U1_VaultCarriesByteIdentical \
  'out = chunks\[:len\(chunks\)-1\] //' 'out = chunks //' \
  'if spans != nil \{\n\t\tout = append\(out, footer\)\n\t\}' '_ = footer'
mut "C3 pkgB not merged" main.go TestUnfetchedCarry_U1_VaultCarriesByteIdentical \
  'pkgBytes = mergeCarried\(pkgBytes, unfPkg\)' '_ = unfPkg'
mut "C4 the spans not merged" main.go TestUnfetchedCarry_U2_ThirdSealCarriesAgain \
  'pkgSpans = mergeCarried\(pkgSpans, unfSpans\)' '_ = unfSpans'
mut "C5 carried although walked" unfetched_carry.go TestUnfetchedCarry_U3_WalkedCopyWins \
  'if walked\[p\] \{' 'if false {'
mut "C6 carriedChunks not counted" main.go TestUnfetchedCarry_U1_LargePackageBeatsTheShrinkGuard \
  'carriedChunks \+= unfN' '_ = unfN'
mut "C7 the drop check removed" unfetched_carry.go TestUnfetchedCarry_U10_DroppedIsNotCarried \
  'if dropPkgForFileRel\(p\+"/x", drop\) \{' 'if false {'
mut "C8 the stored ranges re-recorded side by side" unfetched_carry.go TestUnfetchedCarry_U9_TwoRangesBecomeOne \
  'spans\[p\] = \[\]\[2\]int\{\{start, len\(out\)\}\}' \
  'at := start; for _, r := range oldM.PkgSpan[p] { spans[p] = append(spans[p], [2]int{at, at + r[1] - r[0]}); at += r[1] - r[0] }'
mut "C9 the scope gate removed" unfetched_carry.go TestUnfetchedCarry_U6_OtherScopesNeverCarry \
  'if strings\.IndexByte\(profile, .#.\) >= 0 && !strings\.HasSuffix\(profile, "#de"\) \{' 'if strings.IndexByte(profile, 0) >= 0 {'
mut "C10 the incrementalSeal gate removed" unfetched_carry.go TestUnfetchedCarry_U7_FullSealRefusesUnknown \
  'if !incrementalSeal\(\) \|\| len\(chunks\) == 0 \{' 'if len(chunks) == 0 {'
mut "C11 the nil map not allocated" unfetched_carry.go TestUnfetchedCarry_U11_EmptyWalkCarries \
  'if dst == nil \{\n\t\tdst = map\[string\]V\{\}\n\t\}' ''
mut "C12 the reader's verdict ignored" unfetched_carry.go TestUnfetchedCarry_U4_UntrustedSpanRefused \
  'c, _, ok := pkgSpanChunks\(oldM, p\)\n\t\tif !ok \{\n\t\t\tcontinue\n\t\t\}' \
  'c, _, _ := pkgSpanChunks(oldM, p); for _, r := range oldM.PkgSpan[p] { c = append(c[:0:0], oldM.Chunks[r[0]:r[1]]...) }'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
