#!/usr/bin/env bash
# test-shrink-android.sh [--mutate] -- runs shrink_android_intent_test.go (NWP-20261129-04); --mutate re-runs it against
# main.go and shrink_intent.go with the android marker's verdict broken in turn, restoring both on exit. Each mutant must
# be CONVICTED with a --- FAIL; one that does not apply or does not compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestShrinkAndroid_' .)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
if [[ "$out" == *'no tests to run'* ]]; then echo "FAILED: go test selected no tests"; exit 1; fi
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/orig.main"
cp shrink_intent.go "$W/orig.intent"
trap 'cp -f "$W/orig.main" main.go; cp -f "$W/orig.intent" shrink_intent.go; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local o r
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
  o=$("${RUN[@]}" 2>&1); r=$?
  score_mutant "$1" "$r" "$o" || fails=$((fails+1))
  cp -f "$W/orig.main" main.go
  cp -f "$W/orig.intent" shrink_intent.go
}
mut "M1 the android branch in the marker case is removed" main.go 'if kind == "android" \{\n\s*explained, short := shrinkAndroidExplains.*?(\n\s*return allowed\n)' '\1'
mut "M2 the shortfall sums every short package, not only the declared ones" shrink_intent.go 'for _, p := range declared \{\n\t\tif seen\[p\] \|\| drop\[p\] \{' '_ = declared
	for p := range oldPkg {
		if seen[p] || drop[p] {'
mut "M3 an android marker is allowed outright" shrink_intent.go '\tif kind == "android" \{\n\t\treturn false, nil[^\n]*\n\t\}\n' ''
mut "M4 markProfileShrinkAndroid overwrites a deliberate marker" shrink_intent.go 'case in\.armed && in\.kind == "deliberate":\n\t\t\tcontinue\n' ''
mut "M5 the one-fifth slack is removed" shrink_intent.go 's\*5 >= lost\*4' 's >= lost'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
