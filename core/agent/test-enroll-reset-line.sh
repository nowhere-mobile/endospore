#!/usr/bin/env bash
# test-enroll-reset-line.sh [--mutate] -- runs the damaged create-throttle cases in enroll_reset_line_test.go
# (NWP-20261119-22, h49 #11): a damaged file gives a full bucket and one reset line with a fixed reason word; a missing
# file and a valid bucket log nothing. --mutate re-runs them against main.go with enrollAllow broken in turn, restoring
# the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a
# failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=main.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run '^TestEnrollResetLine\w*$' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res rc
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/$F.orig" "$F"
}
MISS='\t\t// unseen device: the full bucket, silently\n'
GATE='\tif resetWhy != \"\" {\n'
TAIL='(h49 #11, by design)\\n\", path, resetWhy, max)'
mut "R1 the reset line is removed" \
  "(lambda r: r[0] if r[1] == 1 else None)(re.subn(r'\n[^\n]*was unreadable \(%s\)[^\n]*', '', s))"
mut "R2 the reset line is also printed for a missing file" \
  "s.replace('$MISS', '\t\tresetWhy = \"read-error\"\n', 1) if s.count('$MISS') == 1 else None"
mut "R3 a damaged file fails closed (an empty bucket)" \
  "s.replace('$GATE', '$GATE\t\tb.Tokens = 0\n', 1) if s.count('$GATE') == 1 else None"
mut "R4 the reset line prints the file's bytes" \
  "s.replace('$TAIL', '(h49 #11, by design) %s\\\\n\", path, resetWhy, max, raw)', 1) if s.count('$TAIL') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
