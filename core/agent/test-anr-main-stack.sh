#!/usr/bin/env bash
# test-anr-main-stack.sh [--mutate] -- runs report_anr_main_test.go (NWP-20261208-18): a session report's anr section
# carries a Nowhere process's "main" stack and the Cmd line of each process its outgoing binder transactions wait on,
# read from the same trace; other apps keep the header cut. --mutate re-runs it against report_issue.go with each rule
# broken in turn. Each mutant must be CONVICTED (a `--- FAIL`); one that fails to apply or to compile is a failure.
# The pristine report_issue.go lives under one temp root; the EXIT trap restores it and removes the root.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap '[ -f "$W/report_issue.go" ] && cp -f "$W/report_issue.go" report_issue.go; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestAnrMain_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp report_issue.go "$W/report_issue.go"
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local label="$1" res rrc
  if ! python3 - report_issue.go "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
    cp -f "$W/report_issue.go" report_issue.go; return
  fi
  res=$("${RUN[@]}" 2>&1); rrc=$?
  score_mutant "$label" "$rrc" "$res" || fails=$((fails+1))
  cp -f "$W/report_issue.go" report_issue.go
}
mut "M1 every trace counts as Nowhere's -> TestAnrMain_OtherAppsKeepTheHeaderCut" \
  'strings\.HasPrefix\(anrCmdLine\(text, anrFirstPid\(text\)\), "com\.nowhere\."\)' 'true'
mut "M2 anrMainExtras not appended -> TestAnrMain_NowhereTraceCarriesMainAndTargets" \
  'out = append\(out, extra\.\.\.\)' '_ = extra'
mut "M3 from-pid filter dropped (1458 appears) -> TestAnrMain_NowhereTraceCarriesMainAndTargets" \
  'm == nil \|\| m\[1\] != pid \{' 'm == nil {'
mut "M4 target lookup always \"not in trace\" -> TestAnrMain_NowhereTraceCarriesMainAndTargets" \
  'anrCmdLine\(raw, tp\); c != ""' '""; c != ""'
mut "M5 the 120-line cap removed -> TestAnrMain_StackCutAt120" \
  'len\(block\) >= maxIssueAnrMainLines' 'len(block) < 0'
mut "M6 header cut counted on len(out) -> TestAnrMain_HeadersOfOtherTracesUnchanged" \
  'if hdr >= maxLines \{' 'if len(out) >= maxLines {'
mut "M7 main block not ended at its blank line (CatcherOnly) -> TestAnrMain_NowhereTraceCarriesMainAndTargets" \
  '(func anrMainExtras.*?)\t\tif t == "" \{\n\t\t\tbreak\n\t\t\}\n' '\1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
