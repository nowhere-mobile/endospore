#!/usr/bin/env bash
# test-report-503.sh [--mutate] -- REPORT-ISSUE answers ERR-DISABLED only for the gateway's "support intake not
# configured" 503; a full or unreadable intake, or a 503 with any other body, answers ERR 503, which both reporters
# show as a failed send (NWP-20261112-04, dn-1101 #2). Plain: the TestReportIssue503 tests. --mutate applies each
# mutant to report_issue.go in place (a pristine copy lives in one temp root, restored after every mutant and on
# exit) and runs the same tests; each must be CONVICTED by a real `--- FAIL`. A mutant that fails to apply or to
# compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(report_issue.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestReportIssue503' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want
  shift 4
  python3 - "$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -run 'TestReportIssue503' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want "* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
CASE='	case code == http.StatusServiceUnavailable && reason == supportNotConfigured:'
OFF=TestReportIssue503NotConfiguredIsDisabled
FULL=TestReportIssue503IntakeFullIsAFailedSend
UNAV=TestReportIssue503IntakeUnavailableIsAFailedSend
PROXY=TestReportIssue503ProxyBodyIsAFailedSend
# M1 and M2 keep `reason` read and change only the arm's truth value: dropping the read would leave `reason`
# declared and not used, and a mutant that does not compile convicts nothing.
mut "M1 every 503 is ERR-DISABLED again" report_issue.go "$CASE" \
  '	case code == http.StatusServiceUnavailable && (reason == supportNotConfigured || true):' "$FULL" "$UNAV" "$PROXY"
mut "M2 the not-configured match removed (every 503 is ERR 503)" report_issue.go "$CASE" \
  '	case false && reason == supportNotConfigured:' "$OFF"
mut "M3 postIssueReport drops the refusal text (back to postJSON)" report_issue.go \
  '	code, reason, err = newGatewayClient(gw, gwDefault).postJSONReason("/support", rep, &resp)' \
  '	code, err = newGatewayClient(gw, gwDefault).postJSON("/support", rep, &resp)' "$OFF"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
