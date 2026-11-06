#!/usr/bin/env bash
# test-logoff-sweep-retry.sh [--mutate] -- runs the media-sweep retry cases (logoff_sweep_retry_test.go; NWP-20261117-03,
# decided 2026-10-28): a sign-out whose sweep does not verify retries it at most three times, after growing gaps, while
# the mount count falls, and counts every failed attempt toward RESTART-UNSAVED. --mutate re-runs them against
# logoff_sweep_retry.go with each rule broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=logoff_sweep_retry.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestLogoffSweepRetry|TestLogoffCutoff_EveryKeptSessionIsWoken' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res rc
  if ! python3 - "$F" "$2" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return
  fi
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/$F.orig" "$F"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
mut "R1 no retries" "$(one "r'logoffSweepRetries    = 3'" "'logoffSweepRetries    = 0'")"
mut "R2 a retry after a count that did not fall" "$(one "r'fell := prevOK && curOK && cur < prev'" "'fell := prevOK && curOK && cur <= prev'")"
mut "R3 a fourth retry" "$(one "r'logoffSweepRetries    = 3'" "'logoffSweepRetries    = 4'")"
mut "R4 equal gaps" "$(one "r'\{5 \* time.Second, 15 \* time.Second, 30 \* time.Second\}'" "'{5 * time.Second, 5 * time.Second, 5 * time.Second}'")"
mut "R5 no superseded check" "$(one "r'if logoffVerdictSuperseded\(uid, claim, \"media sweep retry\", r\) \{'" "'if false {'")"
mut "R6 the per-attempt count dropped" "$(one "r'\t\tnoteMediaSweepFailed\(name, uid\)[^\n]*\n'" "''")"
mut "R7 every reply reads as a count" "$(one "r'return 0, false'" "'return 0, true'")"
mut "R8 no un-stuck check" "$(one "r'if unstuck \{'" "'if unstuck && false {'")"
mut "R9 the gap leaves the stall clock alone" "$(one "r'\t\tsealProgAt = time.Now\(\)\n'" "''")"
mut "R10 the fall test without the readable flags" "$(one "r'fell := prevOK && curOK && cur < prev'" "'fell := cur < prev'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
