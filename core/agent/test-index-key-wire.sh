#!/usr/bin/env bash
# test-index-key-wire.sh [--mutate] -- runs index_key_wire_test.go (NWP-20261129-18); --mutate re-runs it against
# index.go and main.go with each part of the wiring broken in turn, restoring both files on exit. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'for f in index.go main.go; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestIndexKeyWire' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp index.go "$W/index.go.orig"
cp main.go "$W/main.go.orig"
cat >"$W/mut.py" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
mut() { # mut <file> <label> <regex pattern> <repl>
  local res
  python3 "$W/mut.py" "$1" "$3" "$4" || { echo "  INERT     $2 -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $2"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $2 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $2"; fails=$((fails+1)); fi
  cp -f "$W/$1.orig" "$1"
}
mut index.go "K1 the /data branch back to the baked key" \
  'e == nil && verifyEd25519\(dataKey, d, sig\)' 'e == nil && verifyIndexSig(d, sig)'
mut index.go "K2 refreshIndex checks with the baked key" \
  'if !verifyEd25519\(k, body, sig\) \{' 'if !verifyIndexSig(body, sig) {'
mut index.go "K3 the k == \"\" guard removed" \
  '\tif k == "" \{\n\t\treturn [^\n]*\n\t\}\n' ''
mut index.go "K4 servedIndexDataMtime keeps the baked key" \
  'err != nil \|\| !verifyEd25519\(dataKey, d, sig\)' 'err != nil || !verifyIndexSig(d, sig)'
mut index.go "K5 indexCacheKey without the key files" \
  '\t\t\{"q", indexKeySeqPath\}, \{"h", indexKeyHeldPath\},\n' ''
mut index.go "K6 the unsigned branch reads the selected key" \
  '(?<=if baked == nil \{\n\t\treturn nil\n\t\}\n\t)if indexPubKey == "" \{' 'if dataKey == "" {'
mut main.go "K7 the fetch call removed" \
  '\tif strings\.TrimSpace\(indexPubKey\) != "" \{\n\t\tfetchIndexKey\("s3", time\.Now\(\)\.Unix\(\)\)\n\t\}\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
