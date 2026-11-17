#!/usr/bin/env bash
# test-boot-reason.sh [--mutate] -- runs report_boot_reason_test.go (NWP-20261117-28): an issue report carries Android's
# own boot reason (boot_reason, boot_reason_last, boot_reason_history) at every scope, read by /system/bin/getprop; unread
# when the read is empty or refused; the history joined with "; " and capped at 512 bytes. NWP-20261204-13: boot_reason
# falls back to androidboot.bootreason from /proc/bootconfig, then /proc/cmdline (that one value only), boot_reason_src
# names the source, and boot_reason_read says per source why a read did not answer. --mutate re-runs the cases
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
mut "M2 an empty read is written as \"\" (TestBootReasonUnreadWhenEmpty)" report_issue.go 'return bootReasonUnread, "empty"' 'return v, "empty"'
mut "M3 getprop by a relative path" report_issue.go '"/system/bin/getprop", prop' '"getprop", prop'
mut "M4 only the session scope carries the keys" report_issue.go 'range bootReasonMarker\(\)' 'range map[bool]map[string]string{false: bootReasonMarker()}[deviceScope]'
mut "M5 the history lines are not joined" report_issue.go 'strings\.Join\(lines, "; "\)' 'strings.Join(lines, "\\n")'
mut "M6 the values skip statusValue" report_issue.go '\n\t\tv = statusValue\(v, secrets\)\n(\t\tif k == "boot_reason_history")' '\n\1'
mut "M7 boot_reason_last reads the bootloader prop" report_issue.go 'read\("sys\.boot\.reason\.last"\)' 'read("ro.boot.bootreason")'
mut "M8 the bootconfig fallback skipped (TestBootReasonFallsBackToBootconfig)" report_issue.go 'case bcState == "found":' 'case false && bcState == "found":'
mut "M9 the cmdline fallback skipped (TestBootReasonFallsBackToCmdlineOnlyTheReason)" report_issue.go 'case clState == "found":' 'case false && clState == "found":'
mut "M10 the files preferred over getprop (TestBootReasonGetpropWinsOverFiles)" report_issue.go 'case reasonState == "ok":' 'case reasonState == "ok" && bcState != "found" && clState != "found":'
mut "M11 the value check accepts anything (TestBootReasonMalformedValueNotTaken)" report_issue.go 'return reBootReasonValue\.MatchString\(v\)' 'return true'
mut "M12 the cmdline parser returns the whole line (TestBootReasonFallsBackToCmdlineOnlyTheReason)" report_issue.go 'return val, true' 'return raw, true'
mut "M13 denied reported as absent (TestBootReasonReadSaysWhyPerSource)" report_issue.go '(case errors\.Is\(err, fs\.ErrPermission\):\n\t\treturn )"denied"' '\1"absent"'
mut "M14 boot_reason_src always getprop (TestBootReasonFallsBackToBootconfig)" report_issue.go '"boot_reason_src":     src,' '"boot_reason_src":     src[:0] + "getprop",'
mut "M15 propfiles reports only the first entry (TestBootReasonReadSaysWhyPerSource)" report_issue.go 'return strings\.Join\(toks, ","\)' 'return toks[0]'
[ "$fails" -eq 0 ] && echo "== all 15 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
