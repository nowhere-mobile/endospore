#!/usr/bin/env bash
# test-anr-session-floor.sh [--mutate] -- runs report_anr_session_test.go (NWP-20261020-05); --mutate re-runs it
# against report_issue.go / main.go with each anr-floor rule broken in turn, restoring both on exit. Each mutant
# must be CONVICTED (a `--- FAIL`); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
RUN=(go test -count=1 -run 'TestAnrHeaders_|TestReportIssue_Anr|TestRecordAnrSeen|TestForgetUiderrorsFloorRemovesTheAnrSnapshot|TestAnrSnapshot_|TestAnrSectionStays' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -12
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp report_issue.go report_issue.go.orig
cp main.go main.go.orig
trap 'mv -f report_issue.go.orig report_issue.go; mv -f main.go.orig main.go' EXIT
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp report_issue.go.orig report_issue.go; cp main.go.orig main.go; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp report_issue.go.orig report_issue.go; cp main.go.orig main.go
}
mut "M1 seen filter removed" report_issue.go 'e\.IsDir\(\) \|\| seen\[e\.Name\(\)\]' 'e.IsDir()'
mut "M2 nil seen means no filter" report_issue.go '\tif seen == nil \{\n\t\treturn nil, nil // no snapshot: fail closed\n\t\}\n' ''
mut "M3 handleReportIssue passes nil" report_issue.go 'readAnrSeen\(dest\)\)\n' 'nil)
'
mut "M4 offline snapshot before the forget" main.go '(\tforgetUiderrorsFloor\(dest\) [^\n]*\n)(\trecordAnrSeen\(dest\) [^\n]*\n)' '\2\1'
mut "M5 forgetUiderrorsFloor keeps anr.seen" report_issue.go '\n\tos\.Remove\(filepath\.Join\(dest, anrSeenFile\)\)\n\}' '
}'
mut "M6 ENOENT treated as an error" report_issue.go ' && !errors\.Is\(err, fs\.ErrNotExist\)' ''
mut "M7 failed ReadDir keeps the old snapshot" report_issue.go '\t\tos\.Remove\(path\)\n(\t\tfmt\.Fprintf)' '\1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
