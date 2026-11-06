#!/usr/bin/env bash
# test-repoint-scope.sh [--mutate] -- runs the TestRepointScopeHead tests (NWP-20261116-26: repoint-scope on a scope
# head a passphrase change re-pointed into a vault, and the scope-name test); --mutate re-runs them against copies of
# repoint.go with each guard broken in turn, injected with `go test -overlay`, so the source tree is never edited.
# Each mutant must be CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies without a
# FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=repoint.go
PAT='TestRepointScopeHead'
RUN=(go test -count=1 -run "$PAT" .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python-regex pattern> <replacement> [<pattern> <replacement> ...]; every pair must apply once
  local label="$1" m="$W/mut.go" ov="$W/overlay.json" out
  shift
  python3 - "$SRC" "$m" "$@" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst=sys.argv[1:3]
pairs=sys.argv[3:]
s=open(src).read()
for i in range(0,len(pairs),2):
    s,c=re.subn(pairs[i],pairs[i+1],s,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(dst,'w').write(s)
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
mut "R1 the vault branch never taken (always deriveKey)" 'if isV \{' 'if ov = nil; false && isV {'
mut "R2 a vault head written bare" 'putHead\(base, name, pass, vh\)' '_ = vh; putHead(base, name, pass, target)'
mut "R3 Version++ dropped" '\t\tnv\.Version\+\+\n' ''
mut "R4 signVault dropped" '\t\tsignVault\(&nv, key\)\n' ''
mut "R5 pushSnapshot dropped" '\t\tpushSnapshot\(&nv, target, nv\.HeadKind\)\n' ''
mut "R6 the #wallet refusal removed" ' \|\| scopeSealedUnderDK\(name\[len\(bn\):\]\)' ''
mut "R7 the scope test back to strings.Contains" \
  'if bn := profileBaseName\(name\); bn == name \|\| scopeSealedUnderDK\(name\[len\(bn\):\]\) \{' 'if !strings.Contains(name, "#") {' \
  '\t"fmt"\n' '\t"fmt"\n\t"strings"\n'
mut "R8 the errRepointLocked return falls through to deriveKey" 'return ov\.Manifest, m, errRepointLocked' 'key, ov = deriveKey(name, pass), nil'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
