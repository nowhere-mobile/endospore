#!/usr/bin/env bash
# test-index-key-fetch.sh [--mutate] -- runs index_key_fetch_test.go (NWP-20261126-14); --mutate re-runs it against
# index_key_fetch.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure. K10-K17 (NWP-20261210-18) break the h57 #7
# damaged-floor rebuild; each label names the test that convicts it.
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
p,args=sys.argv[1],sys.argv[2:]
if not args or len(args)%2: sys.exit(1)
s=open(p).read()
for pat,rep in zip(args[0::2],args[1::2]):  # every (pattern, replacement) pair must match exactly once
    if len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
    s=re.sub(pat,lambda m: rep,s,count=1,flags=re.S)
open(p,'w').write(s)
PY
fails=0
mut() { # mut <label> <regex pattern> <repl> [<regex pattern> <repl>]
  local res label=$1
  shift
  python3 "$W/mut.py" "$SRC" "$@" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $label"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
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
mut "K10 acceptIndexKey refuses a damaged floor without trying the held copy (TestIndexKeyAcceptDamagedFloorRebuilt)" \
  'if err == errIndexKeyFloorDamaged \{' 'if false {'
mut "K11 the rebuilt floor's seq taken as 0, an older object accepted (TestIndexKeyAcceptDamagedFloorRebuilt)" \
  'seq, stored, err = hobj\.Seq, hh, nil' 'seq, stored, err = 0, hh, nil'
mut "K12 the held copy's signature not checked, one signed by another key rebuilds the floor (TestIndexKeyAcceptBothDamagedRefuses)" \
  '"encoding/hex"\n' '"encoding/hex"
	"encoding/json"
' \
  'obj, err := verifyIndexKeyObject\(indexKeyObjectKey, held, now, 0\)' 'obj, err := func() (*indexKeyObject, error) { _, b, err := openIndexKeyEnvelope(held); var w indexKeyWire; if err == nil { err = json.Unmarshal(b, &w) }; if err != nil || w.Seq == nil { return nil, err }; k := ""; if w.Key != nil { k = *w.Key }; return &indexKeyObject{Schema: 1, Seq: *w.Seq, Key: k, Revoked: w.Revoked}, nil }()'
mut "K13 the floor rewrite skipped (TestIndexKeyAcceptDamagedFloorRebuilt: the floor reads seq 3)" \
  'if werr := writeIndexKeyFile\(seqPath, \[\]byte\(fmt\.Sprintf\("%d %s\\n", hobj\.Seq, hh\)\)\); werr != nil \{' 'if werr := error(nil); werr != nil {'
mut "K14 the rewrite's error ignored (TestIndexKeyAcceptRebuildWriteFails)" \
  '\)\); werr != nil \{' ')); werr != nil && false {'
mut "K15 currentIndexKey's damaged arm returns indexPubKey (TestCurrentIndexKeyDamagedFloorUsesHeld)" \
  'return activeIndexKey\(indexPubKey, hobj\)' 'return indexPubKey'
mut "K16 an unreadable floor (errIndexKeyFloorRead) rebuilt too (TestIndexKeyAcceptUnreadableFloorNotRebuilt)" \
  'if err == errIndexKeyFloorDamaged \{' 'if err != nil {'
mut "K17 currentIndexKey's damaged arm writes the floor (TestCurrentIndexKeyDamagedFloorUsesHeld: floor byte-identical)" \
  'hobj, _, herr := heldIndexKeyFloor\(indexKeyHeldPath, now\)' 'hobj, hh, herr := heldIndexKeyFloor(indexKeyHeldPath, now); if herr == nil { writeIndexKeyFile(indexKeySeqPath, []byte(fmt.Sprintf("%d %s\n", hobj.Seq, hh))) }'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
