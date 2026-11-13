#!/usr/bin/env bash
# test-day-summary.sh [--mutate] -- a beta session's day summary reaches its own reports (NWP-20261124-12, backlog: A
# beta profile has no way to send a diagnostic report on a schedule ...). While $STATE/day-summary-on.<uid> exists
# (DIAG-SUMMARY on, only when GATEWAY_URL's host is the beta gateway), day_summary.go keeps a numbers-only summary in
# $STATE/day-summary.<uid> (a signin line, a line per periodic or manual save from triggerRoamWorkerKind's deferred
# writer, a line per DIAG-EVENT sweep; 24 h; non-save lines 4 KiB; 16 KiB in total), and an in-session report carries it whole as day_summary. Each
# save line ends kib=<upload KiB> from that run's seal split, "-" when the run left none (NWP-20261128-29). Every
# REPORT-ISSUE sent at session scope adds a report line (the caller's report_kind, the reply's class, no ticket) after
# its reply, so the next report shows it (NWP-20261202-11).
#
# Runs day_summary_test.go. --mutate breaks each guard in turn on a COPY of the package; each mutant must be
# CONVICTED by a real `--- FAIL`. One that fails to apply or compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestDaySummary'

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

echo; echo "== mutants (each MUST be convicted) =="
fails=0
# mut <label> <file> <regex> <replacement>: exactly one substitution in a package copy; needs a real `--- FAIL`, and
# the names of the tests that failed are printed. The copy is <R>/agent beside a link to the real ../vendor-common:
# TestDaySummaryBetaHostMatchesRings reads ../vendor-common/etc/rings, and a copy without it failed that test for every
# mutant, so every mutant read as convicted whatever it broke (NWP-20261128-29).
VC=$(cd ../vendor-common && pwd) || exit 2
mut() {
  local label=$1 file=$2 R P res mrc
  R=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  P="$R/agent"
  { cp -a . "$P" && ln -s "$VC" "$R/vendor-common"; } || { fails=$((fails+1)); rm -rf "$R"; return; }
  python3 - "$P/$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$R"; return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); mrc=$?
  if score_mutant "$label" "$mrc" "$res"; then
    sed -n 's/^--- FAIL: \([^ ]*\).*/      by \1/p' <<<"$res"
  else
    fails=$((fails+1))
  fi
  rm -rf "$R"
}

mut "m1 the caller check dropped" day_summary.go \
  '&& peer >= 0 && strconv\.Itoa\(peer/100000\) == uid ' '&& peer == peer '
mut "m2 offered reads issueGatewayURL (the baked default fallback)" day_summary.go \
  'url\.Parse\(strings\.TrimSpace\(os\.Getenv\("GATEWAY_URL"\)\)\)' 'url.Parse(strings.TrimSpace(issueGatewayURL()))'
mut "m3 offered always true" day_summary.go \
  'return err == nil && u\.Scheme == "https" && u\.Host == daySummaryBetaHost' '_, _ = u, err\n\treturn true'
mut "m4 the writer ignores the marker" day_summary.go \
  '\tif !daySummaryOn\(uid\) \{\n\t\treturn\n\t\}\n(\tpath := daySummaryPath\(uid\)\n\tnow)' '\1'
mut "m5 the reader accepts any line" day_summary.go \
  'if _, ok := daySummaryLineT\(l\); !ok \{' 'if _, ok := daySummaryLineT(l); !ok && false {'
mut "m6 the merge runs at device scope" day_summary.go \
  'if deviceScope \|\| status == nil' 'if status == nil'
mut "m13 caller day_* keys kept at device scope (RF-001)" day_summary.go \
  '\tfor k := range status \{ // a nil map ranges zero times\n\t\tif strings\.HasPrefix\(k, "day_"\) \{' '\tif deviceScope {\n\t\treturn\n\t}\n\tfor k := range status {\n\t\tif strings.HasPrefix(k, "day_") {'
mut "m7 the 24 h prune removed" day_summary.go \
  'ok && now-t <= int64\(daySummaryMaxAge/time\.Second\)' 'ok && now-t <= 1<<40'
mut "m8 the 16 KiB prune removed" day_summary.go \
  'for size > daySummaryMaxBytes && len\(keep\) > 1 \{' 'for false && size > daySummaryMaxBytes && len(keep) > 1 {'
mut "m9 the deferred save writer removed from triggerRoamWorkerKind" main.go \
  '\n\tdefer daySummaryRecordSave\(op, intent, uid, dest, time\.Now\(\)\.Round\(0\), &res\)[^\n]*' ''
mut "m10 manual saves not recorded" day_summary.go \
  '\(intent != "periodic" && intent != "manual"\)' 'intent != "periodic"'
mut "m11 the completed sign-out does not forget" main.go \
  '\n\t+daySummaryForget\(uid\)[^\n]*' ''
mut "m12 the report does not merge the summary" report_issue.go \
  '\n\tmergeDaySummary\(rep\.Status, uid, deviceScope\)[^\n]*' ''
mut "M-kib1 the save kib ignores the reply's verdict" day_summary.go \
  'if !sealSplitVerdicts\[sealVerb\(out\)\] \{' 'if false {'
mut "M-kib2 the save kib reads an older run's split" day_summary.go \
  'if err != nil \|\| st\.ModTime\(\)\.Before\(t0\) \{' 'if err != nil || st.ModTime().IsZero() {'
mut "M-kib3 the save kib counts a ?KiB entry as 0" push_stat.go \
  'if m == nil \|\| m\[3\] == "\?" \{\n\t\t\treturn 0, false\n\t\t\}' 'if m == nil {\n\t\t\treturn 0, false\n\t\t}\n\t\tif m[3] == "?" {\n\t\t\tcontinue\n\t\t}'
mut "M-keep1 the size pass drops the oldest line of any kind" day_summary.go \
  'i := daySummaryOldest\(keep, true\)' 'i := 0'
mut "M-keep2 the kept-class budget pass disabled" day_summary.go \
  'for kept > daySummaryKeptMaxBytes \{' 'for false && kept > daySummaryKeptMaxBytes {'
mut "M-keep3 the kept-class pass drops the newest kept line" day_summary.go \
  'i := daySummaryOldest\(keep, false\)' 'i := daySummaryOldest(keep, false)\n\t\tfor j := range keep {\n\t\t\tif !daySummaryIsSave(keep[j]) {\n\t\t\t\ti = j\n\t\t\t}\n\t\t}'
mut "M-keep4 daySummaryIsSave always true" day_summary.go \
  'func daySummaryIsSave\(l string\) bool \{ return daySummarySaveRe\.MatchString\(l\) \}' 'func daySummaryIsSave(l string) bool { return true }'
mut "m14 the report shape dropped from the reader" day_summary.go \
  'daySummarySweepRe, daySummaryReportRe\}' 'daySummarySweepRe}'
mut "m15 the report kind always scheduled" day_summary.go \
  '(func daySummaryReportKind\(v string\) string \{\n)' '\1\treturn "scheduled"\n'
mut "m16 the send-path report record removed" report_issue.go \
  '\n\tdaySummaryRecordReport\(uid, deviceScope, kind, daySummaryReportRC\(reply\)\)[^\n]*' ''
mut "m17 the preview records a report line" report_issue.go \
  '(\t\tfmt\.Fprint\(conn, "\\n"\)\n)(\t\treturn\n)' '\1\t\tdaySummaryRecordReport(uid, deviceScope, kind, "ok")\n\2'
mut "m18 the report writer ignores device scope" day_summary.go \
  '\tif deviceScope \{\n\t\treturn\n\t\}\n(\tdaySummaryAppend\(uid, fmt\.Sprintf\("v=1 t=%d ev=report)' '\1'
mut "m19 the report rc keeps the ticket" day_summary.go \
  '(case reply == "OK" \|\| strings\.HasPrefix\(reply, "OK "\):\n\t\treturn "ok")' '\1 + strings.TrimPrefix(reply, "OK")'
[ "$fails" -eq 0 ] && echo "== all 26 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
