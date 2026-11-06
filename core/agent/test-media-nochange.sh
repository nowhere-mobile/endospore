#!/usr/bin/env bash
# test-media-nochange.sh [--mutate] -- runs the no-change #media push tests (NWP-20261123-04); --mutate re-runs them
# with media_nochange.go or main.go broken in turn, restoring both files on exit. Each mutant must be CONVICTED by a
# `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'MediaNoChange' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp media_nochange.go "$W/media_nochange.go.orig"
cp main.go "$W/main.go.orig"
trap 'cp -f "$W/media_nochange.go.orig" media_nochange.go 2>/dev/null; cp -f "$W/main.go.orig" main.go 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/media_nochange.go.orig" media_nochange.go; cp "$W/main.go.orig" main.go; }
# conv <label>: run the suite against the mutated files, then restore them.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: Test'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <file> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$2" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
mut "M1 the digest without mtime" media_nochange.go '\n\td\.i64\(info\.ModTime\(\)\.UnixNano\(\)\)\n' '\n'
mut "M2 the stored-head check dropped" media_nochange.go '\t\tcase in\.head == "" \|\| rh != in\.head:[^\n]*\n\t\t\treturn false\n' ''
mut "M3 the tombstone check dropped" media_nochange.go '\t\tcase !mediaTombstonesEmpty\(in\.src\):[^\n]*\n\t\t\treturn false\n' ''
mut "M3b a tombstones file of blank lines accepted" media_nochange.go 'case err != nil, !fi\.Mode\(\)\.IsRegular\(\), fi\.Size\(\) != 0:' 'case err != nil, !fi.Mode().IsRegular():'
mut "M3c a tombstones path it cannot inspect accepted" media_nochange.go 'case err != nil, !fi\.Mode\(\)\.IsRegular\(\), fi\.Size\(\) != 0:' 'case err == nil && fi.Mode().IsRegular() && fi.Size() != 0:'
mut "M4 the record committed before the head PUT lands" main.go 'mnoFlushed := !capMode\(\)' 'mnoFlushed := true'
mut "M5 the record names the manifest, not a vault scope's committed head" main.go '\n\t\tcommittedHead = vh\n' '\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
