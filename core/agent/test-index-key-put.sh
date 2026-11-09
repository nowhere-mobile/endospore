#!/usr/bin/env bash
# test-index-key-put.sh [--mutate] -- runs index_key_put_test.go (NWP-20261129-24); --mutate re-runs it against
# index_key_put.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a real
# `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
SRC=index_key_put.go
trap '[ -f "$W/orig" ] && cp -f "$W/orig" "$SRC"; rm -rf "$W"' EXIT
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestIndexKeyPut|TestIndexKeyCheck' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/orig"
cat >"$W/mut.py" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
mut() { # mut <label> <regex pattern> <repl, may use \1>
  local res rc
  python3 -I "$W/mut.py" "$SRC" "$2" "$3" || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/orig" "$SRC"
}
mut "P1 an equal seq allowed" 'if obj\.Seq <= p\.Seq \{' 'if obj.Seq < p.Seq {'
mut "P2 the published read's error ignored (published blind)" \
  'if err != nil \{(\s*)return nil, "", fmt\.Errorf\("the published object could not be read' \
  'if _ = err; false {\1return nil, "", fmt.Errorf("the published object could not be read'
mut "P3 a published object that fails verification read as none" \
  'if perr != nil \{(\s*)return nil, "", fmt\.Errorf\("the published object does not verify' \
  'if perr != nil {\n\t\t\tp = &indexKeyObject{}\n\t\t}\n\t\tif false {\1return nil, "", fmt.Errorf("the published object does not verify'
mut "P4 the ref written before the blob" \
  '"fmt"\n(.*?)h := postBlob\(store, env\)\n\tputRef\(store, indexKeyRefName, h\)' \
  '"crypto/sha256"\n\t"encoding/hex"\n\t"fmt"\n\1sum := sha256.Sum256(env)\n\th := hex.EncodeToString(sum[:])\n\tputRef(store, indexKeyRefName, h)\n\tpostBlob(store, env)'
mut "P5 the cap check removed" 'if len\(env\) > indexKeyEnvMax \{' 'if false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
