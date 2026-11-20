#!/usr/bin/env bash
# test-ssaid-prefill-report.sh [--mutate] -- the census of the settings_ssaid.xml SettingsProvider pre-filled reaches
# an in-session issue report (NWP-20261207-16; the backlog row "On a boot after a flash or an OTA, the bundled apps of
# every sign-in share one ANDROID_ID"). roamd's seedssaid arm writes $STATE/ssaid-prefill (v=1 none, v=1
# unread=<class>, or v=1 rows=<n> userkey=<n> apps=<n> distinct=<n> largest=<n>); ssaid_prefill.go reads it into
# ssaid_prefill* status keys, at session scope only, because it is the sign-in's own user table. The roamd half is
# core/vendor-common/bin/test-ssaid-census.sh.
#
# This suite runs ssaid_prefill_test.go. --mutate breaks each guard in turn on a COPY of the package; each mutant must
# be CONVICTED by a real `--- FAIL`. One that fails to apply or compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestSsaidPrefill'

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

mut "G1 the counts shape loosened to any v=1 line (TestSsaidPrefillMalformed)" ssaid_prefill.go \
  'regexp\.MustCompile\(`\^v=1 rows=[^`]*`\)' 'regexp.MustCompile(`^v=1 (.*)()()()()$`)'
mut "G2 the deviceScope guard dropped: the keys at every scope (TestSsaidPrefillReportScope)" report_issue.go \
  '(\n\tfor k, v := range extra \{)' \
  '\n\tfor k, v := range ssaidPrefillStatus(filepath.Join(loginStateDir(), ssaidPrefillFile)) {\n\t\tstatus[k] = v\n\t}\1'
mut "G3 a counts key copied from the wrong group (TestSsaidPrefillShapes)" ssaid_prefill.go \
  '("ssaid_prefill_apps": +string\(m\[)3\]' '\g<1>2]'
[ "$fails" -eq 0 ] && echo "== all 3 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
