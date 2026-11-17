#!/usr/bin/env bash
# test-od-grow-timing.sh [--mutate] -- this session's odrestore du timings reach an in-session issue report
# (NWP-20261202-34; docs/product-decisions.md 2026-11-01, h50 #1: a handset measurement of what the size walk costs
# every 10 seconds). roamd's od_watched merges its timed `du -sk` reads into $STATE/od-grow-timing
# (v=1 vols=<n> reads=<n> du_ms=<n> max_ms=<n> kib=<n>); od_grow_timing.go reads it into five status keys, at session
# scope only, because an app's data size is a profile fact. The roamd half is test-odrestore-growth.sh (T1-T5) and
# test-grant-timing.sh (D, the reset at each sign-in).
#
# This suite runs od_grow_timing_test.go. --mutate breaks each guard in turn on a COPY of the package; each mutant must
# be CONVICTED by a real `--- FAIL`. One that fails to apply or compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestOdGrowTiming'

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

echo; echo "== mutants (each MUST be convicted) =="
fails=0
# mut <label> <file> <regex> <replacement>: exactly one substitution in a package copy; needs a real `--- FAIL`
mut() {
  local label=$1 file=$2 P res
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P" || { fails=$((fails+1)); return; }
  python3 - "$P/$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  rm -rf "$P"
}

mut "g1 the reader's shape loosened to .* (TestOdGrowTimingMalformed)" od_grow_timing.go \
  'regexp\.MustCompile\(`\^v=1 vols=[^`]*`\)' 'regexp.MustCompile(`^(.*)()()()()$`)'
mut "g2 the deviceScope guard dropped: the keys at every scope (TestOdGrowTimingReportScope)" report_issue.go \
  '(\n\tfor k, v := range extra \{)' \
  '\n\tfor k, v := range odGrowTimingStatus(filepath.Join(loginStateDir(), odGrowTimingFile)) {\n\t\tstatus[k] = v\n\t}\1'
mut "g3 a missing file mapped to unreadable (TestOdGrowTimingMissing)" od_grow_timing.go \
  '(errors\.Is\(err, fs\.ErrNotExist\) \{\n\t\treturn )map\[string\]string\{\}' '\1unreadable'
[ "$fails" -eq 0 ] && echo "== all 3 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
