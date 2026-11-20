#!/usr/bin/env bash
# test-reap-hold-report.sh [--mutate] -- runs reap_hold_report_test.go (NWP-20261204-21, Q039): every cleanstorage op's
# RW-lane hold and the slot wait of a sign-in that queued behind one reach every issue report, at both scopes, as
# <1/1-5/5-20/>=20 s buckets with the max. --mutate re-runs the cases against a COPY of the package with each part
# broken in turn; the checked-out files are never edited. Each mutant must be CONVICTED by its named test's
# `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 180s -run '^(TestReapHold|TestIssueReportCarriesReapHold)' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/agent"
mkdir "$P" && cp -a . "$P" || exit 2
FILES=(reap_hold_report.go main.go report_issue.go)
fails=0
mut() { # mut <label> <expected failing test> <file> <python-regex> <replacement>: exactly one substitution, or INERT
  local label=$1 want=$2 file=$3 f res rc
  for f in "${FILES[@]}"; do cp -f "$f" "$P/$f" || { fails=$((fails+1)); return; }; done
  python3 - "$P/$file" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
if len(re.findall(pat, s, flags=re.S)) != 1: sys.exit(1)
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1, flags=re.S)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
  if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  elif [ "$rc" -ne 0 ] && [[ "$res" == *"--- FAIL: $want "* ]]; then echo "  convicted $label ($want)"
  else echo "  SURVIVED  $label -- no --- FAIL: $want"; tail -n 15 <<<"$res"; fails=$((fails+1)); fi
}

mut "M1 the 1 s boundary made >" TestReapHoldBuckets reap_hold_report.go \
  'case ms >= 1000:' 'case ms > 1000:'
mut "M2 the reapHold record removed" TestReapHoldRecordsEveryReap main.go \
  '\t+reapHold\.add\(h\.Milliseconds\(\)\)[^\n]*\n' ''
mut "M3 the reapHold record gated on the >2 s branch" TestReapHoldRecordsEveryReap main.go \
  'if op == "cleanstorage" \{(\n\t+reapHold\.add)' 'if op == "cleanstorage" && h > 2*time.Second {\1'
mut "M4 the op test widened to every op" TestReapHoldIgnoresOtherOps main.go \
  'if op == "cleanstorage" \{(\n\t+reapHold\.add)' 'if true {\1'
mut "M5 the behindReap holder test removed" TestReapHoldSigninOnFreeLane main.go \
  'behindReap = h == "cleanstorage"' 'behindReap = h == h'
mut "M6 behindReap read after the acquire" TestReapHoldSigninBehindReap main.go \
  '(\tbehindReap := false\n\tif op == "in" \{\n\t\th, _ := rwHolderOp\.Load\(\)\.\(string\)\n\t\tbehindReap = h == "cleanstorage"\n\t\}\n)(.*?\n)(\tif behindReap \{\n)' '\2\1\3'
mut "M7 reap_lane_hold gated on !deviceScope" TestIssueReportCarriesReapHold report_issue.go \
  '(\tstatus\["reap_lane_hold"\] = reapHold\.value\(\)\n)' '\tif !deviceScope {\n\1\t}\n'
mut "M8 signin_wait_behind_reap removed" TestIssueReportCarriesReapHold report_issue.go \
  '\tstatus\["signin_wait_behind_reap"\] = signinWaitBehindReap\.value\(\)\n' ''
[ "$fails" -eq 0 ] && echo "== all 8 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
