#!/usr/bin/env bash
# test-seal-writer.sh [--mutate] -- runs seal_writer_test.go (NWP-20261201-12, h62 #4: each push's roam.log line names what
# it found changed since the last seal, by writer class and data kind, in counts and fixed words only). --mutate re-runs it
# against copies of seal_writer.go and incremental_seal.go with each rule broken in turn, injected with `go test -overlay`,
# so the source tree is never edited. Each mutant must be CONVICTED by a real `--- FAIL` of every test it names; one that
# does not apply, does not compile, fails another test only, or dies without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestSealWriter' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <tests that must fail, space-separated> <file> <python-regex pattern> <replacement> [more pairs]
  local label="$1" wants="$2" src="$3" m="$W/mut.go" ov="$W/overlay.json" out want
  python3 - "$src" "$m" "${@:4}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst=sys.argv[1:3]
rest=sys.argv[3:]
s=open(src).read()
for pat,rep in zip(rest[0::2],rest[1::2]):
    s,c=re.subn(pat,lambda _m:rep,s,flags=re.S)
    if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  out=$(go test -count=1 -overlay "$ov" -run 'TestSealWriter' . 2>&1)
  if [[ "$out" == *'build failed'* ]]; then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  for want in $wants; do
    if grep -q -- "--- FAIL: $want " <<<"$out"; then
      echo "  convicted $label: $(grep -m1 -- "--- FAIL: $want " <<<"$out")"
    elif grep -q -- '--- FAIL' <<<"$out"; then
      echo "  WRONG-TEST $label -- $want did not fail: $(grep -m1 -- '--- FAIL' <<<"$out")"; fails=$((fails+1))
    elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
      echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
    else
      echo "  SURVIVED  $label"; fails=$((fails+1))
    fi
  done
}
mut "m1 the play set returns app" "TestSealWriterClass TestSealWriterTallyNamesTheChangedWriter" seal_writer.go \
  'return "play"' 'return "app"'
mut "m2 a group hit counted as a miss" TestSealWriterTallyNamesTheChangedWriter incremental_seal.go \
  'sc\.noteGroup\(key, gs\.start, gs\.end, true, true, regFiles\)\n' $'sc.noteGroup(key, gs.start, gs.end, true, true, regFiles)\n\t\t\t\tsc.noteWriterGroupMiss(g)\n'
mut "m3 the since test dropped, every file counted" TestSealWriterTallyNamesTheChangedWriter seal_writer.go \
  'if sc\.writer\.since\.IsZero\(\) \|\| info\.ModTime\(\)\.Before\(sc\.writer\.since\) \{' 'if sc.writer.since.IsZero() {'
mut "m4 the line prints the map keys, keyed by the package" TestSealWriterLineNamesNoPackage seal_writer.go \
  'for _, w := range words \{' 'for w := range m {' \
  'class := sealWriterClass\(e\.rel\)' 'class := attrPkgForRel(e.rel)' \
  'class, kind := sealWriterClass\(rel\), sealWriterKind\(rel\)' 'class, kind := attrPkgForRel(rel), sealWriterKind(rel)'
mut "m5 the forceFull guard removed from sealWriterLine" TestSealWriterForceFull seal_writer.go \
  'if !forceFull \{' 'if true {'
mut "m6 newFileScanCache records no baseline" TestSealWriterBaselineIsTheGroupCacheTime incremental_seal.go \
  'sc\.writer\.since = fi\.ModTime\(\)' '_ = fi'
mut "m7 beginWalk does not start the counters again" TestSealWriterBaselineIsTheGroupCacheTime incremental_seal.go \
  '\t*sc\.writer\.reset\(\)\n' ''
mut "m8 the large-file arm does not count" TestSealWriterLargeFileCounted incremental_seal.go \
  'st\.large\+\+\n\t*sc\.noteWriterFile\(rel, info\) // NWP-20261201-12\n' $'st.large++\n'
mut "m9 a forced walk counts group misses" TestSealWriterForceFull incremental_seal.go \
  'if !forceFull \{\n(\t*sc\.noteWriterGroupMiss)' $'if true {\n\t\t\tsc.noteWriterGroupMiss'
mut "m10 the small-file arm does not count" TestSealWriterTallyNamesTheChangedWriter incremental_seal.go \
  '\t*sc\.noteWriterFile\(rel, info\) // NWP-20261201-12: this arm[^\n]*\n' ''
[ "$fails" -eq 0 ] && echo "== all 10 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
