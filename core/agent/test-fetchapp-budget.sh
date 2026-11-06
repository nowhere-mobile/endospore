#!/usr/bin/env bash
# test-fetchapp-budget.sh [--mutate] -- runs the FETCH-APP download-bound cases (fetchapp_budget_test.go plus
# TestFetchAndVerify; NWP-20261107-03); --mutate re-runs them against catalog.go with the bound broken in turn,
# restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=catalog.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestFetchAppBudget|TestFetchAndVerify' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$F.orig" "$F"
}
mut "M1 the copied client keeps the store client's total timeout" \
  "s.replace('\tc.Timeout = 0\n', '', 1) if s.count('\tc.Timeout = 0\n') == 1 else None"
mut "M2 the stall timer is never reset by a byte" \
  "s.replace('\t\ts.t.Reset(s.d)\n', '\t\t_ = s.d\n', 1) if s.count('\t\ts.t.Reset(s.d)\n') == 1 else None"
mut "M3 the entry's size is ignored" \
  "s.replace('\tlimit := maxBytes\n', '\tlimit := fetchAppMaxBytes\n\t_ = maxBytes\n', 1) if s.count('\tlimit := maxBytes\n') == 1 else None"
mut "M4 the over-size error no longer says mismatch" \
  "s.replace('\"size mismatch: more', '\"size over: more', 1) if s.count('\"size mismatch: more') == 1 else None"
mut "M5 the connection deadline is back to 300 s" \
  "s.replace('time.Now().Add(fetchAppBudget + fetchAppStageAllowance))', 'time.Now().Add(300 * time.Second))', 1) if s.count('time.Now().Add(fetchAppBudget + fetchAppStageAllowance))') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
