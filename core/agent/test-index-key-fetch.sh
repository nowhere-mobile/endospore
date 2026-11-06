#!/usr/bin/env bash
# test-index-key-fetch.sh [--mutate] -- runs index_key_fetch_test.go (NWP-20261126-14); --mutate re-runs it against
# index_key_fetch.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
SRC=index_key_fetch.go
trap '[ -f "$W/orig" ] && cp -f "$W/orig" "$SRC"; rm -rf "$W"' EXIT
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestIndexKeyFetch|TestIndexKeyAccept|TestCurrentIndexKey' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/orig"
cat >"$W/mut.py" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local res
  python3 "$W/mut.py" "$SRC" "$2" "$3" || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp -f "$W/orig" "$SRC"
}
mut "K1 the same-hash arm verifies above the floor (the floor's own object refused)" \
  'verifyIndexKeyObject\(indexKeyObjectKey, env, now, seq-1\)' 'verifyIndexKeyObject(indexKeyObjectKey, env, now, seq)'
mut "K2 the new-object arm verifies at floor-1 (a different same-seq object accepted)" \
  'obj, err := verifyIndexKeyObject\(indexKeyObjectKey, env, now, seq\)' 'obj, err := verifyIndexKeyObject(indexKeyObjectKey, env, now, seq-1)'
mut "K3 the floor written before the held copy" \
  'if err := writeIndexKeyFile\(heldPath, env\)' 'writeIndexKeyFile(seqPath, []byte(fmt.Sprintf("%d %s\n", obj.Seq, h))); if err := writeIndexKeyFile(heldPath, env)'
mut "K4 the held write's error ignored" \
  'if err := writeIndexKeyFile\(heldPath, env\); err != nil \{' 'if err := writeIndexKeyFile(heldPath, env); err != nil && false {'
mut "K5 a damaged floor read as floor 0" \
  'return 0, "", errIndexKeyFloorDamaged' 'return 0, "", nil'
mut "K6 currentIndexKey skips the hash comparison" \
  'if hex\.EncodeToString\(sum\[:\]\) != stored \{' 'if _, _ = sum, stored; false {'
mut "K7 currentIndexKey returns indexPubKey on a hash mismatch" \
  '(?<=\(seq %d\)\\n", seq\)\n\t\t)return ""' 'return indexPubKey'
mut "K8 the fetch's name check removed" \
  'if sum := sha256\.Sum256\(b\); hex\.EncodeToString\(sum\[:\]\) != h \{' 'if false {'
mut "K9 the recover returns the panic's text (it can hold the store URL)" \
  'env, err = nil, errIndexKeyStore' 'env, err = nil, fmt.Errorf("%v", p)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
