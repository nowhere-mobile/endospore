#!/usr/bin/env bash
# test-fetchapp-progress.sh [--mutate] -- runs the FETCH-APP progress cases (fetchapp_progress_test.go;
# NWP-20261122-14): with the `progress` opt-in the reply starts "PROGRESS 0 <total>", then PROGRESS lines with the
# running total, then one verdict line; without it, never a PROGRESS line; a reader that goes away never holds the
# handler; each PROGRESS write is bounded. --mutate re-runs them against catalog.go with each part broken in turn,
# restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile
# is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=catalog.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestFetchAppProgress' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res rc
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import sys
p, expr = sys.argv[1:3]
s = open(p).read()
def once(old, new, t=None):
    t = s if t is None else t
    return t.replace(old, new, 1) if t.count(old) == 1 else None
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/$F.orig" "$F"
}
mut "P1 PROGRESS lines without the opt-in" \
  "once('progressOn := len(fields) > 2 && fields[2] == \"progress\"', 'progressOn := true')"
mut "P2 the start line dropped" \
  "once('\\tsendProgress(start, 0)\\n', '')"
mut "P3 got reported as the read's count, not the running total" \
  "once('sendProgress(now, got)', 'sendProgress(now, int64(k))')"
mut "P4 the PROGRESS write deadline removed" \
  "once('conn.SetWriteDeadline(now.Add(2 * time.Second))\\n', '\\n')"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
