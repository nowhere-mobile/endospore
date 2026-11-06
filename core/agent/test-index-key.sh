#!/usr/bin/env bash
# test-index-key.sh [--mutate] -- runs index_key_test.go (NWP-20261124-25); --mutate re-runs it against index_key.go
# with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
SRC=index_key.go
trap '[ -f "$W/orig" ] && cp -f "$W/orig" "$SRC"; rm -rf "$W"' EXIT
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestIndexKey' .)

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
mut "K1 domain prefix dropped from the verify" 'msg = append\(append\(msg, indexKeyDomain\.\.\.\), body\.\.\.\)' 'msg = append(msg, body...)'
mut "K2 seq > floor relaxed to >=" 'if seq <= floor \{' 'if seq < floor {'
mut "K3 a revoked baked key still selected" '(if indexKeyIn\(baked, obj\.Revoked\) \{\s*return )""' '\1baked'
mut "K4 self-revoked check removed" 'if w\.Key != nil && indexKeyIn\(\*w\.Key, w\.Revoked\) \{' 'if false {'
mut "K5 signature checked after the schema" '(\tif !verifyReleaseSig\(pubB64, msg, sig\) \{\n.*?\n\t\}\n)(.*?\tif w\.Schema == nil \|\| \*w\.Schema != 1 \{\n.*?\n\t\}\n)' '\2\1'
mut "K6 revoked keys compared as strings" 'err == nil && bytes\.Equal\(rb, k\)' 'err == nil && bytes.Equal(rb, k) && r == key'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
