#!/usr/bin/env bash
# test-cap-remint-retry.sh [--mutate] -- runs the TestCapPut_ tests (NWP-20261113-10: capPutErr spends its one re-mint
# only when POST /cap produced a cap, logs a failed re-mint and tries it again on the next attempt, and logs a refused
# fresh cap's X-Amz-Date/X-Amz-Expires against the device clock); --mutate re-runs them against a COPY of the package
# with each part of that rule broken in turn. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply,
# or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestCapPut_' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party testdata "$P"/ || exit 2
cp "$P/main.go" "$W/main.go.orig" || exit 2
fails=0
# mut <label> <python-regex> <replacement>: apply to the copy's main.go (the regex must match exactly once), run the
# tests there, score the run, then restore the pristine copy.
mut() {
  local label="$1" res rc
  if python3 - "$P/main.go" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/main.go.orig" "$P/main.go"
}
mut "M1 the one re-mint is spent before refresh() runs again" \
  '(\n(\t+)nu, nh, rerr := refresh\(\)\n)' '\n\2reminted = true\1'
mut "M2 a failed re-mint is no longer logged" \
  'fmt\.Fprintf\(os\.Stderr, "  cap PUT: re-mint failed \(%s\).*?logSafeStoreErr\("cap PUT", rerr\)\)' '_ = rerr'
mut "M3 every 403 re-mints (no one-shot)" \
  'if !reminted \{' 'if !reminted || true {'
mut "M4 a refused fresh cap no longer logs when it was signed" \
  'fmt\.Fprintf\(os\.Stderr, "  cap PUT: the re-minted cap was refused too.*?"20060102T150405Z"\)\)' '_, _ = date, exp'
mut "M5 the refused-fresh-cap line prints the whole cap URL" \
  'code, date, exp, time\.Now\(\)' 'code, cur+date, exp, time.Now()'
[ "$fails" -eq 0 ] && echo "== all 5 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
