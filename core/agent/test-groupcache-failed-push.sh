#!/usr/bin/env bash
# test-groupcache-failed-push.sh [--mutate] -- runs groupcache_failed_push_test.go (NWP-20261123-05: a cap-mode vault
# push whose flush fails on a blob PUT, when the fake gateway resets the connection, leaves every unchanged small-file
# group reusable at the next seal; a chunk whose PUT failed is never known present; the group-cache line names the
# every-Nth-seal full re-hash, and only on that seal). --mutate re-runs it against copies of main.go with each guard
# broken in turn, injected with `go test -overlay`, so the source tree is never edited. Mutants: m1 the forced re-hash
# suffix dropped, m2 the suffix printed on every seal, m4 every buffered blob marked known at flush start. (No m3: test
# F passed on unchanged code, so there was no defect to fix and no fix to revert.) Each mutant must be CONVICTED by a
# real `--- FAIL` of the test it names; one that does not apply, does not compile, fails another test only, or dies
# without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestFailedPush_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <test that must fail> <file> <python-regex pattern> <replacement>
  local label="$1" want="$2" src="$3" m="$W/mut.go" ov="$W/overlay.json" out
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
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run 'TestFailedPush_' . 2>&1)
  if grep -q -- "--- FAIL: $want " <<<"$out"; then
    echo "  convicted $label: $(grep -m1 -- "--- FAIL: $want " <<<"$out")"
  elif grep -q -- '--- FAIL' <<<"$out"; then
    echo "  WRONG-TEST $label -- $want did not fail: $(grep -m1 -- '--- FAIL' <<<"$out")"; fails=$((fails+1))
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "m1 the forced re-hash suffix dropped" TestFailedPush_ForcedRehashIsNamed main.go \
  'if forceFull \{\n(\t\t\tfull = fmt\.Sprintf\(" \(full re-hash)' $'if false && forceFull {\n\t\t\tfull = fmt.Sprintf(" (full re-hash'
mut "m2 the suffix printed on every seal" TestFailedPush_ForcedRehashIsNamed main.go \
  'if forceFull \{\n(\t\t\tfull = fmt\.Sprintf\(" \(full re-hash)' $'if true || forceFull {\n\t\t\tfull = fmt.Sprintf(" (full re-hash'
mut "m4 every buffered blob marked known at flush start" TestFailedPush_UnputChunkNotKnown main.go \
  'if len\(st\.blobs\) == 0 && len\(st\.refs\) == 0 \{\n\t\treturn\n\t\}\n' \
  $'if len(st.blobs) == 0 && len(st.refs) == 0 {\n\t\treturn\n\t}\n\tfor _, b := range st.blobs {\n\t\tif strings.HasPrefix(b.key, "blob/") {\n\t\t\tblobCacheAdd(b.key[len("blob/"):])\n\t\t}\n\t}\n'
[ "$fails" -eq 0 ] && echo "== all 3 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
