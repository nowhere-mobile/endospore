#!/usr/bin/env bash
# test-boot-reason.sh [--mutate] -- runs report_boot_reason_test.go (NWP-20261117-28): an issue report carries Android's
# own boot reason (boot_reason, boot_reason_last, boot_reason_history) at every scope, read by /system/bin/getprop; unread
# when the read is empty or refused; the history joined with "; " and capped at 512 bytes. --mutate re-runs the cases
# against a COPY of the package with each guard broken in turn. Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestBootReason'

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <regex> <replacement>: exactly one substitution of <regex> in <file> of a package copy, or INERT
  local label=$1 file=$2 P res rc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P" || { fails=$((fails+1)); rm -rf "$P"; return; }
  python3 - "$P/$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
if len(re.findall(pat, s)) != 1: sys.exit(1)
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}

mut "M1 the history is not capped" report_issue.go 'v = capBytes\(v, bootReasonHistoryCap\)' 'v = v'
mut "M2 an empty read is written as \"\"" report_issue.go 'if err != nil \|\| v == "" \{' 'if err != nil {'
mut "M3 getprop by a relative path" report_issue.go '"/system/bin/getprop", prop' '"getprop", prop'
mut "M4 only the session scope carries the keys" report_issue.go 'range bootReasonMarker\(\)' 'range map[bool]map[string]string{false: bootReasonMarker()}[deviceScope]'
mut "M5 the history lines are not joined" report_issue.go 'strings\.Join\(lines, "; "\)' 'strings.Join(lines, "\\n")'
mut "M6 the values skip statusValue" report_issue.go '\n\t\tv = statusValue\(v, secrets\)\n(\t\tif k == "boot_reason_history")' '\n\1'
mut "M7 boot_reason_last reads the bootloader prop" report_issue.go 'read\("sys\.boot\.reason\.last"\)' 'read("ro.boot.bootreason")'
[ "$fails" -eq 0 ] && echo "== all 7 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
