#!/usr/bin/env bash
# test-seal-group-cache.sh [--mutate] -- runs group_cache_test.go (NWP-20261119-01, h49 #4: a seal reuses an unchanged
# small-file group by hash and opens none of its files; groups flush at each top-level directory; the incremental arm
# has no progress pre-walk, and the walk's frames claim no total); --mutate re-runs it against copies of
# incremental_seal.go / main.go / group_cache_test.go with each guard broken in turn, injected with `go test -overlay`,
# so the source tree is never edited. Each mutant must be CONVICTED by a real
# `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestGroupCache' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label="$1" src="$2" m="$W/mut.go" ov="$W/overlay.json" out
  python3 - "$src" "$m" "${@:3}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
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
  out=$(go test -count=1 -overlay "$ov" -run 'TestGroupCache' . 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label: $(grep -m1 -- '--- FAIL' <<<"$out")"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "m1 getGroup ignores blobCacheKnown" incremental_seal.go \
  '(cs := sc\.groups\[key\]\n\tsc\.mu\.Unlock\(\)\n\tif len\(cs\) == 0 \{\n\t\treturn nil\n\t\}\n)\tfor _, h := range cs \{\n\t\tif !blobCacheKnown\(h\) \{\n\t\t\treturn nil\n\t\t\}\n\t\}\n' \
  $'cs := sc.groups[key]\n\tsc.mu.Unlock()\n\tif len(cs) == 0 {\n\t\treturn nil\n\t}\n'
mut "m2 a torn group is cached" incremental_seal.go 'case clean && start >= 0:' 'case start >= 0:'
mut "m3 the key omits mtime" incremental_seal.go \
  'i64\(e\.info\.Size\(\)\)\n\t\t\ti64\(e\.info\.ModTime\(\)\.UnixNano\(\)\)' 'i64(e.info.Size())'
mut "m4 no flush at a top-level change" incremental_seal.go 'if groupTop != "" && u != groupTop \{' 'if false && groupTop != "" && u != groupTop {'
mut "m5 forceFull ignored for groups" incremental_seal.go \
  'getGroupIf\(use bool, key string\) \[\]string \{\n\tif !use \{' $'getGroupIf(use bool, key string) []string {\n\tif false && !use {'
mut "m6 the progress pre-walk kept in the incremental arm" main.go \
  'if !incrementalSeal\(\) \{\n\t\tvar sum int64' $'if true {\n\t\tvar sum int64'
mut "m7 the walk frame claims a total (visited bytes as the whole)" incremental_seal.go \
  'line := fmt\.Sprintf\("sizes 0 %d", beat\)' 'line := fmt.Sprintf("data %d %d", done, done+beat)'
mut "m8 the walk frame does not change from beat to beat" incremental_seal.go \
  'line := fmt\.Sprintf\("sizes 0 %d", beat\)' 'line := fmt.Sprintf("sizes 0 %d", 1)'
mut "m9 the dispatch judgement reads the shared progress frame again" group_cache_test.go \
  'if tv := \(\*total\)\.Load\(\); tv != 0 \{' 'if tv := (*total).Load(); tv != 0 || func() bool { b, _ := os.ReadFile(os.Getenv("NOWHERE_PROGRESS")); f := strings.TrimRight(string(b), "\n"); return f != "" && !strings.HasPrefix(f, "sizes 0 ") }() {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
