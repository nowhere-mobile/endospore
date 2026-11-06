#!/usr/bin/env bash
# test-floor-corpus.sh [--mutate] -- runs the floor-corpus verb's tests (NWP-20261119-24, h49 #5); --mutate re-runs them
# against floor_corpus.go broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a `--- FAIL`; one
# that fails to apply, or fails to compile, counts as a failure. C1 the runner prints refused entries; C2 a local copy of
# the rule; C3 a profile name passed to the rule; C4 the grid bound changed; C5 the capitalised forms dropped; C6 the
# de-dup dropped.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=floor_corpus.go
RUN=(go test -count=1 -run 'TestFloorCorpus' .)

W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp "$SRC" "$W/floor_corpus.go.orig"
trap 'cp -f "$W/floor_corpus.go.orig" "$SRC" 2>/dev/null; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { cp "$W/floor_corpus.go.orig" "$SRC"; }
# conv <label>: run the suite against the mutated file, then restore it.
conv() {
  local res rc
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$SRC" "$2" "$3" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
mut "C1 the runner prints refused entries" 'if !floorCorpusCheck\(entry\) \{\s*return false, nil\s*\}' '_ = floorCorpusCheck(entry)'
mut "C2 a local copy of the rule" 'ok, _ := passphraseStrong\("", entry\)' 'ok := len([]rune(strings.Join(strings.Fields(entry), " "))) >= 12'
mut "C3 a profile name passed to the rule" 'passphraseStrong\("", entry\)' 'passphraseStrong(entry, entry)'
mut "C4 the grid bound changed" 'floorCorpusGridK = 10 ' 'floorCorpusGridK = 12 '
mut "C5 the capitalised forms dropped" '\t\tadd\(ws\.\.\.\)\n' '		_ = ws
'
mut "C6 the de-dup dropped" 'if seen\[p\] \{\s*return\s*\}' '_ = seen[p]'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
