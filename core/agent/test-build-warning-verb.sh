#!/usr/bin/env bash
# test-build-warning-verb.sh [--mutate] -- runs build_warning_verb_test.go (NWP-20261120-03): GET-BUILD-WARNING answers
# WARN only when the daemon's cached warning names the running build and has not expired, and it is lock-free
# (concurrentSafeCmd), so a sign-in or a reap holding sessionMu never delays the gate. --mutate copies core/agent into a
# temp dir and breaks the COPY in turn (the tree is never edited); each mutant must be CONVICTED by a real `--- FAIL`,
# and one that does not apply or does not compile is a failure. Nothing is left in $TMPDIR.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestGetBuildWarning' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

mkdir "$W/pristine" && cp -a . "$W/pristine/" || { echo "FAILED: could not copy the tree"; exit 1; }
rm -f "$W/pristine/nowhere_agent"
cat >"$W/mut.py" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local res rc
  rm -rf "$W/m" && cp -a "$W/pristine" "$W/m" || { echo "  BROKEN    $1 -- could not copy the tree"; fails=$((fails+1)); return; }
  python3 "$W/mut.py" "$W/m/$2" "$3" "$4" || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$(cd "$W/m" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
}
mut "V1 GET-BUILD-WARNING dropped from concurrentSafeCmd" main.go \
  '\n\t\t"GET-BUILD-WARNING",\n' '\n'
mut "V2 the handler answers WARN when the warning does not affect this build" build_warning_fetch.go \
  'if buildWarningAffects\(buildWarningVersion\(\)' 'if !buildWarningAffects(buildWarningVersion()'
mut "V3 the handler passes an empty version" build_warning_fetch.go \
  'buildWarningAffects\(buildWarningVersion\(\), ' 'buildWarningAffects("", '
mut "V4 the dispatch line removed" main.go \
  '\tif name == "GET-BUILD-WARNING" \{\n\t\thandleGetBuildWarning\(conn\)[^\n]*\n\t\treturn\n\t\}\n' ''
rm -rf "$W/m"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
