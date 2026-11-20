#!/usr/bin/env bash
# test-report-odhold-log.sh [--mutate] -- runs report_odhold_log_test.go and the two trim-order tests (NWP-20261206-15,
# the evidence for the backlog row "installd is denied `setattr` on the files of an on-demand app's parked data ...").
# --mutate re-runs them against a PACKAGE COPY per mutant with one rule of the odhold_log section broken in turn. Each
# mutant must be CONVICTED (a `--- FAIL`); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestOdholdLog|TestTrimOrderReachesEverySection|TestEverySectionIsReachableByTheDeleteStep' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local d res
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
  then echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; fi
  res=$(cd "$d" && "${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  rm -rf "$d"
}
F=report_odhold_log.go
mut "O1 the /.nowhere-odhold/ filter removed (TestOdholdLogDropsLinesOutsideTheHold)" "$F" 'if !strings\.Contains\(msg, "/\.nowhere-odhold/"\) \{' 'if false {'
mut "O2 the head allowlist removed, a package leaks (TestOdholdLogHeadAllowlist)" "$F" 'if !odholdHeadRe\.MatchString\(head\) \{' 'if false {'
mut "O3 de mapped to ce (TestOdholdLogHoldClasses)" "$F" '\{"de", regexp' '{"ce", regexp'
mut "O4 the errno list replaced by any text (TestOdholdLogErrnoClasses)" "$F" 'if !odholdErrnoTexts\[errno\] \{' 'if false {'
mut "O5 the device-scope guard removed (TestOdholdLogMergeScope)" "$F" 'if deviceScope \{' 'if false {'
mut "O6 the NO-source header removed (TestOdholdLogSectionHeaders)" "$F" 'head = append\(head, "odhold_log: NO source could be read -- .*?alone"\)' '_ = bad'
mut "O7 odhold_log dropped from issueTrimOrder (TestEverySectionIsReachableByTheDeleteStep)" report_issue.go '"uiderrors", "odhold_log", "prev_boot"' '"uiderrors", "prev_boot"'
mut "O8 the 40-line cap removed (TestOdholdLogCap)" "$F" 'if len\(out\) > odholdLogMaxGroups \{' 'if false {'
mut "O9 the uid filter removed (TestOdholdLogUidFilter)" "$F" 'if u == nil \|\| u\[1\] != uid \{' 'if u == nil {'
mut "O10 the mergeOdholdLog call removed from handleReportIssue (TestOdholdLogReachesTheIssueReport)" report_issue.go '\tmergeOdholdLog\(&rep, uid, deviceScope, nameSpellings\(name\)\.\.\.\) +//[^\n]*\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
