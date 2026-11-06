#!/usr/bin/env bash
# test-warn-and-tell.sh [--mutate] -- runs warn_and_tell_test.go (NWP-20261016-47, docs/product-decisions.md
# 2026-10-16, "warn and tell"): GET-PARKED-CREDIT, the warning's daemon half, and the restart's lost-credit notice kept
# outside the state tmpfs for the gate after the boot. --mutate re-runs it against main.go / wallet_restore.go /
# end_unsaved.go with each rule broken in turn, restoring the files on exit.
#
# A mutant is CONVICTED only by a failing assertion: `--- FAIL: TestWarnAndTell_` in the output. One that does not
# apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass -- a compile error proves nothing about
# the rule, so a mutant that would leave a variable unused keeps it used (G12, G15). The go version is printed first,
# so the log shows which toolchain ran. G2 is the blind-login rule: the gate's answer must not tell a stored parked
# session from a throwaway.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
go version || { echo "FAIL: no go toolchain -- this suite did NOT run" >&2; exit 1; }
RUN=(go test -count=1 -run 'TestWarnAndTell_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

FILES=(main.go wallet_restore.go end_unsaved.go)
for f in "${FILES[@]}"; do cp "$f" "$f.orig"; done
trap 'for f in "${FILES[@]}"; do mv -f "$f.orig" "$f"; done' EXIT
fails=0
mut() { # mut <label> <file> <python regex> <replacement>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re, sys
p, pat, rep = sys.argv[1:4]
s = open(p).read()
n, c = re.subn(pat, rep, s, count=1, flags=re.S)
if c != 1 or n == s:
    sys.exit(1)
open(p, 'w').write(n)
PY
  local o
  o=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL: TestWarnAndTell_' <<<"$o"; then
    echo "  convicted $1"
  elif grep -q -e '\[build failed\]' -e '\[setup failed\]' <<<"$o"; then
    echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  else
    echo "  SURVIVED  $1"; fails=$((fails+1))
  fi
  for f in "${FILES[@]}"; do cp "$f.orig" "$f"; done
}
mut "G1 GET-PARKED-CREDIT answers any caller" main.go \
  '(if name == "GET-PARKED-CREDIT" \{\n(?:\t\t//[^\n]*\n)*)\t\tif !creditLostCallerOK\(conn\) \{' '\1\t\tif false {'
mut "G2 the gate's answer tells a throwaway from a stored profile" wallet_restore.go \
  'if _, lost := supersedeLosesCredit\(dest, ""\); lost \{' 'if _, lost := supersedeLosesCredit(dest, ""); lost && !isLocalSession(dest) {'
mut "G3 a loss judged with nothing parked" wallet_restore.go \
  'parked != "" && parked != newUID && ' 'parked != newUID && '
mut "G4 the gate's answer is always NONE" wallet_restore.go \
  '(if _, lost := supersedeLosesCredit\(dest, ""\); lost \{\n\t\treturn )"LOST"' '\1"NONE"'
mut "G5 the restart tells nothing" end_unsaved.go \
  'if tell != "" \{\n\t\tnoteRestartCreditLost\(tell\)' 'if false {\n\t\tnoteRestartCreditLost(tell)'
mut "G6 the restart tells whatever the session held" end_unsaved.go \
  'ok == endUnsavedCreditLost && walletHoldsCredit\(walletPathFor\(dest\)\)' 'ok == endUnsavedCreditLost'
mut "G7 a restart that saved the wallet tells too" end_unsaved.go \
  'if ok == endUnsavedCreditLost && walletHoldsCredit' 'if walletHoldsCredit'
mut "G8 the notice is written before the restart can refuse" end_unsaved.go \
  '(tell = strconv\.FormatInt\(time\.Now\(\)\.Unix\(\), 10\)\n)(.*?)\t// NWP-20261016-47: after the last refusal[^\n]*\n\tif tell != "" \{\n\t\tnoteRestartCreditLost\(tell\)\n\t\}\n' \
  '\1\t\tnoteRestartCreditLost(tell)\n\2'
mut "G9 the marker carries no notice time" end_unsaved.go \
  'if tell != "" \{\n\t\tbody \+=' 'if false {\n\t\tbody +='
mut "G10 a restart that did not happen keeps its notice" end_unsaved.go \
  '\tretractRestartCreditLost\(restartMarkerTell\(dest\)\)\n' ''
mut "G11 a daemon start drops a marker that carries a notice" end_unsaved.go \
  '\(len\(f\) != 2 && len\(f\) != 3\)' 'len(f) != 2'
mut "G12 the take-back removes any notice" wallet_restore.go \
  'err == nil && strings\.TrimSpace\(string\(b\)\) == stamp \{' 'err == nil && len(b) >= 0 {'
mut "G13 GET-CREDIT-LOST shows a notice whose reboot has not happened" wallet_restore.go \
  'ok && restartNoticeDue\(dest, ts\) \{' 'ok {'
mut "G14 GET-CREDIT-LOST never reads the restart's notice" wallet_restore.go \
  'if ts, ok := creditLostStamp\(restartCreditLostPath\); ok && restartNoticeDue\(dest, ts\) \{' 'if ts, ok := "", false; ok {'
mut "G15 CLEAR-CREDIT-LOST clears every notice" wallet_restore.go \
  '\t\tcase got == s:\n' '\t\tcase got == s || true:\n'
mut "G16 CLEAR-CREDIT-LOST counts a pending restart's notice" wallet_restore.go \
  '\t\tcase p == restartCreditLostPath && !restartNoticeDue\(dest, got\):\n' ''
mut "G17 the daemon start removes the notice itself" wallet_restore.go \
  'func dropRestartCreditLostTmp\(\) \{ os\.Remove\(restartCreditLostPath \+ "\.tmp"\) \}' 'func dropRestartCreditLostTmp() { os.Remove(restartCreditLostPath) }'
mut "G18 another function names the notice" main.go \
  '\tdropRestartCreditLostTmp\(\)\n' '\tos.Remove(restartCreditLostPath + ".tmp")\n'
mut "G19 the supersede logs a throwaway's loss" wallet_restore.go \
  'if !lost \|\| parkedLocal \{' 'if !lost {'
mut "G20 the daemon start never drops the .tmp" main.go \
  '\tdropRestartCreditLostTmp\(\)\n' ''
mut "G21 the notice is world-readable" wallet_restore.go \
  'os\.WriteFile\(tmp, \[\]byte\(stamp\), 0o600\)' 'os.WriteFile(tmp, []byte(stamp), 0o644)'
mut "G22 the notice is written in place" wallet_restore.go \
  'tmp := restartCreditLostPath \+ "\.tmp"' 'tmp := restartCreditLostPath'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
