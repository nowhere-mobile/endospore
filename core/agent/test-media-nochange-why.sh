#!/usr/bin/env bash
# test-media-nochange-why.sh [--mutate] -- runs the no-change #media push tests with NWP-20261204-22's: the tombstones
# key in the record's digest, and the one line that names the guard which refused the exit or kept no record.
# --mutate re-runs them with media_nochange.go or main.go broken in turn, restoring both files on exit. Each mutant
# must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
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
# T1: TestMediaNoChange_TombstonesKeyFields (same-length different content).
mut "T1 the tombstones key hashes lengths only" media_nochange.go '\n\t\td\.h\.Write\(b\)\n' '\n'
# T2: TestMediaNoChange_ATombstoneAppendedAfterTheRecordTakesTheFullPath, EachGuardNamesItself (tombs=1 case).
mut "T2 the tombstones key always empty" media_nochange.go '\treturn d\.sum\(\), true\n' '\treturn "", true\n'
# T3: TestMediaNoChangeWhy_EachGuardNamesItself (digest-doubt), TestMediaNoChange_TombstonesKeyFields.
mut "T3 a tombstones doubt read as a key" media_nochange.go '(case err != nil, !fi\.Mode\(\)\.IsRegular\(\):\n\t\t\treturn "", )false\n' '\1true\n'
# T4: TestMediaNoChange_UnchangedTreeEndsAfterTheWalk, TombstonesSealedThenUnchangedEndsEarly.
mut "T4 the record staged with the walk digest alone" main.go 'mediaNoChangeAfterSeal\(cct, committedHead, mnoDigest,' 'mediaNoChangeAfterSeal(cct, committedHead, sealStats.digest,'
# T5: TestMediaNoChange_TombstonesSealedThenUnchangedEndsEarly.
mut "T5 the old empty-only tombstones arm restored" main.go '(\t\t\tmnoDigest = mediaNoChangeDigest\(sealStats\.digest, tk, tok\)\n)' '\1\t\t\tif mediaTombstonesCount(src) != 0 {\n\t\t\t\tmnoDigest = ""\n\t\t\t}\n'
# W1: TestMediaNoChangeWhy_EachGuardNamesItself, NoChangeLinePrintsNoReason.
mut "W1 the full-path line removed" main.go '\t\t\tfmt\.Printf\(mediaNoChangeFullLine, [^\n]*\n' ''
# W2: TestMediaNoChangeWhy_EachGuardNamesItself (head-moved, digest-changed).
mut "W2 head-moved and digest-changed swap tokens" media_nochange.go 'return "head-moved"(.*?)return "digest-changed"' 'return "digest-changed"\1return "head-moved"'
# W3: TestMediaNoChangeWhy_EachGuardNamesItself (digest-changed by a tombstone, tombs=1).
mut "W3 tombs= always 0" main.go '(fmt\.Printf\(mediaNoChangeFullLine, logProfile\(profile\), why, )mediaTombstonesCount\(src\)\)' '\g<1>0)'
# W4: TestMediaNoChangeWhy_RecordNotKeptNamesWhy (not-landed).
mut "W4 the not-landed line removed" main.go '(\t\tif why != "" \{\n\t\t\t)fmt\.Printf\(mediaNoChangeNotKeptLine, logProfile\(profile\), why\)\n' '\1_ = why\n'
# W5: TestMediaNoChangeWhy_TheLineNamesNothing, EachGuardNamesItself.
mut "W5 the full-path line prints the digest" main.go 'fmt\.Printf\(mediaNoChangeFullLine, logProfile\(profile\), why,' 'fmt.Printf(mediaNoChangeFullLine, logProfile(profile), mnoDigest,'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
