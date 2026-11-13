#!/usr/bin/env bash
# test-vpnstate-report.sh [--mutate] -- runs vpn_state_report_test.go (NWP-20261202-43: an in-session issue report
# carries the always-on VPN's live state as vpn_state and a sent one appends a codes-only ev=vpnstate day-summary
# line) and TestDaySummarySourcePins; --mutate re-runs them against a COPY of the package with each part broken in
# turn. Each mutant must be CONVICTED by a `--- FAIL` from the test its label names; one that fails to apply, or fails
# to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run '^TestVpnStateReport|^TestDaySummarySourcePins$' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <convicting test> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then
# restore the file. Convicted only by a `--- FAIL: <convicting test>`.
mut() {
  local label="$1" test="$2" f="$3" res
  cp "$P/$f" "$W/orig.go"
  if python3 - "$P/$f" "$4" "$5" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *"--- FAIL: $test "* ]]; then echo "  convicted $label (by $test)"
    else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "R1 gate scope gets the key" TestVpnStateReportGateScopeAbsent report_issue.go \
  'delete\(rep\.Status, "vpn_state"\)\n\tif deviceScope \{' 'delete(rep.Status, "vpn_state")\n\tif false {'
mut "R2 a preview appends the day-summary line" TestVpnStateReportPreviewAppendsNothing report_issue.go \
  'v != "" && !req\.Preview \{' 'v != "" {'
mut "R3 the caller-sent key survives" TestVpnStateReportCallerKeyRemoved report_issue.go \
  '\tdelete\(rep\.Status, "vpn_state"\)\n' ''
mut "R4 the reply regex loosened" TestVpnStateReportJunkIsUnavailable report_issue.go \
  'net=\(1\|0\|-\)\$`\)\n\n// mergeVpnState' 'net=(1|0|-)`)\n\n// mergeVpnState'
mut "R5 laneFor drops vpnstate" TestVpnStateReportLane main.go \
  '\tcase "vpnstate":\n\t\t// NWP-20261202-43: three secure-settings reads and one package dump for an issue report\. Its own' \
  '\tcase "vpnstate-x":\n\t\t// NWP-20261202-43: three secure-settings reads and one package dump for an issue report. Its own'
mut "R6 the day-summary reader drops the vpnstate shape" TestVpnStateReportShapeRoundTrips day_summary.go \
  'daySummarySaveRe, daySummaryVpnStateRe, ' 'daySummarySaveRe, '
mut "R7 the append moved between mergeSigninSummary and mergeDaySummary" TestDaySummarySourcePins report_issue.go \
  '(\tif v := mergeVpnState.*?\n\t\}\n)(.*?mergeSigninSummary\(rep\.Status, uid, deviceScope\)[^\n]*\n)' '\2\1'
mut "R8 the vpnstate worker sends the passphrase" TestVpnStateReportWorkerSendsNoPass report_issue.go \
  'triggerRoamWorker\(dest, "vpnstate", name, "", uid' 'triggerRoamWorker(dest, "vpnstate", name, name, uid'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
