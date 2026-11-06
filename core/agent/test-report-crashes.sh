#!/usr/bin/env bash
# test-report-crashes.sh [--mutate] -- runs report_crashes_test.go (NWP-20261128-17, Q121: an in-session issue report
# carries this session's app crashes and crash_access; a gate report carries neither). --mutate re-runs the tests
# against a PACKAGE COPY per mutant, each with one rule of mergeCrashes or its wiring broken. A mutant is CONVICTED
# only by a `--- FAIL: <its named test>` line; one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestReportCrashes' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement> <test that must fail>
  local d res nl=$'\n'
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R ./*.go go.mod go.sum blindrsa testdata third_party "$d"/
  if ! python3 - "$d/$2" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; fi
  res=$(cd "$d" && "${RUN[@]}" 2>&1)
  if [[ "$nl$res" == *"$nl--- FAIL: $5 "* ]]; then
    echo "  convicted $1 ($5)"
  else
    echo "  SURVIVED  $1 -- no --- FAIL: $5 line"; tail -n 15 <<<"$res"; fails=$((fails+1))
  fi
  rm -rf "$d"
}
mut "K1 the deviceScope guard removed" report_crashes.go 'if rep == nil \|\| deviceScope \{' 'if rep == nil {' TestReportCrashesGateCarriesNothing
mut "K2 the scrub skipped" report_crashes.go 'lines = scrubIssueLines\(lines, nameSpellings\(name\)\)' '_ = nameSpellings(name)' TestReportCrashesNameRedacted
mut "K3 crashes removed from issueTrimOrder" report_issue.go '"ota\.log", "crashes", ' '"ota.log", ' TestReportCrashesTrimmable
mut "K4 the access allow-list removed" report_crashes.go 'if crashAccessValues\[access\] \{' 'if access != "" {' TestReportCrashesAccessValue
mut "K5 the merge call removed" report_issue.go '\tmergeCrashes\(&rep, [^\n]*\n' '	_ = req.Crashes
' TestReportCrashesSessionCarries
mut "K6 the line cap removed" report_crashes.go '\tif n := len\(lines\); n > maxIssueCrashLines \{\n\t\tlines = lines\[n-maxIssueCrashLines:\]\n\t\}\n' '' TestReportCrashesCaps
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
