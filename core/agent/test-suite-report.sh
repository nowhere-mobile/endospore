#!/usr/bin/env bash
# test-suite-report.sh [--mutate] -- pins suite-report.sh (NWP-20261022-14): fabricated outputs for a green run, a
# failed assertion, a binary that exited and a build error, plus a sweep that the twenty-one agent suites report
# through it and that no other suite (bar the four temp-making ones) sends "$out" into a bare `tail -5`. Also pins
# score_mutant (NWP-20261110-03), the verdict of a --mutate run: a --- FAIL line with a non-zero status convicts, a run with
# neither that nor an ok line is BROKEN with its tail shown, and no agent suite pipes echo/printf of a variable into grep -q.
# --mutate breaks the helper and one suite in turn; each mutant must be CONVICTED (an INERT one is a failure).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SUITES=(test-bound-budget test-coldlock-rekey-result test-create-keep-wallet test-delete-busy-seal test-jitter-epochs
  test-keyed-resume-preproof test-logoff-rearm-inbox test-logoff-watchdog-supersede test-reboot-fallback-pending
  test-recover-store-reply test-recreate-purge-time test-resolver-plain-err test-rollback-gate-se test-rollback-guard
  test-rollback-inbox test-rotate-ks-stash test-seal-unresolved-session test-selinux-level test-storage-breakdown-under
  test-tel-handoff-readfail test-warn-and-tell)
MUTSUITES=(test-catalog-rollback test-coldlock-rekey-result test-gate-alarm-relay test-gate-alarm-silence-log
  test-legacy-guard test-logoff-watchdog-supersede test-logout-wallet test-tel-handoff-readfail test-storage-breakdown-under)
PIPEQ='(echo|printf)[^|#]*\$[{A-Za-z_][^|#]*\|[[:space:]]*grep[^|]*[[:space:]]-[A-Za-z]*q'
TEMPMAKERS=(test-lost-start-recovery test-mailbox-rules test-owner-key-rewrap test-tel-replay-persist)
SENT='no --- FAIL line'

# run_case <helper> <rc> <output>: sets CASE_OUT and CASE_RC; a subshell, so nothing leaks between cases.
run_case() {
  CASE_OUT=$(set -uo pipefail; . "$1"; report_plain_run "$2" "$3"); CASE_RC=$?
}

# run_score <helper> <label> <rc> <output>: sets CASE_OUT and CASE_RC of score_mutant; a subshell like run_case.
run_score() {
  CASE_OUT=$(set -uo pipefail; . "$1"; score_mutant "$2" "$3" "$4"); CASE_RC=$?
}

check_all() { # check_all <helper> <suite_dir>: prints a line per failure, returns the number of them
  local helper="$1" dir="$2" bad=0 expect last tail_part
  local green fail_out panic_out build_out conv big i n f s t hits line files=0

  green=$(printf 'l%s\n' 1 2 3 4 5 6 7 8 9)
  expect=$(printf 'l%s\n' 5 6 7 8 9)
  run_case "$helper" 0 "$green"
  if [ "$CASE_RC" -ne 0 ] || [ "$CASE_OUT" != "$expect" ]; then echo "FAIL (a) green: want the last five lines and status 0, got rc=$CASE_RC"; bad=$((bad+1)); fi

  fail_out=$(printf 'first-marker\n--- FAIL: TestX (0.01s)\n    x_test.go:12: boom\n'; printf '[logind] noise %s\n' 1 2 3 4 5 6 7 8 9 10 11 12; printf 'FAIL\nFAIL\tnowhereagent\t0.5s\n')
  run_case "$helper" 1 "$fail_out"
  tail_part=${CASE_OUT#*== failing tests:}
  last=${CASE_OUT##*$'\n'}
  if [ "$CASE_RC" -ne 1 ]; then echo "FAIL (b) assertion: status $CASE_RC, want 1"; bad=$((bad+1)); fi
  if [[ "$CASE_OUT" != first-marker* ]]; then echo "FAIL (b) assertion: the whole output is not printed"; bad=$((bad+1)); fi
  if [[ "$tail_part" != *'--- FAIL: TestX'* || "$tail_part" == "$CASE_OUT" ]]; then echo "FAIL (b) assertion: the --- FAIL line is not in the summary"; bad=$((bad+1)); fi
  if [ "$last" != FAILED ]; then echo "FAIL (b) assertion: last line is '$last', want FAILED"; bad=$((bad+1)); fi

  panic_out=$(printf 'panic: runtime error: index out of range\n\ngoroutine 1 [running]:\nmain.main()\nFAIL\tnowhereagent\t0.2s\n')
  run_case "$helper" 1 "$panic_out"
  if [ "$CASE_RC" -ne 1 ]; then echo "FAIL (c) panic: status $CASE_RC, want 1"; bad=$((bad+1)); fi
  if [[ "$CASE_OUT" != *"$SENT"* ]]; then echo "FAIL (c) panic: the '$SENT' sentence is missing"; bad=$((bad+1)); fi

  build_out=$(printf '# nowhereagent\n./main.go:10:2: undefined: foo\n./main.go:11:2: undefined: bar\n./main.go:12:2: x\n./main.go:13:2: y\nFAIL\tnowhereagent [build failed]\n')
  run_case "$helper" 2 "$build_out"
  if [ "$CASE_RC" -ne 1 ] || [[ "$CASE_OUT" != '# nowhereagent'* ]]; then echo "FAIL (d) build error: want the whole output and status 1, got rc=$CASE_RC"; bad=$((bad+1)); fi

  run_score "$helper" "L" 1 $'--- FAIL: TestX (0.01s)\n    x_test.go:12: boom\nFAIL\nFAIL\tnowhereagent\t0.5s'
  if [ "$CASE_RC" -ne 0 ] || [ "$CASE_OUT" != "  convicted L" ]; then echo "FAIL (h) conviction: want '  convicted L' and status 0, got rc=$CASE_RC '$CASE_OUT'"; bad=$((bad+1)); fi
  run_score "$helper" "L" 1 $'=== RUN   TestX\n    --- FAIL: TestX/sub (0.00s)\nFAIL'
  if [ "$CASE_RC" -ne 0 ] || [ "$CASE_OUT" != "  convicted L" ]; then echo "FAIL (i) indented --- FAIL: want convicted and status 0, got rc=$CASE_RC '$CASE_OUT'"; bad=$((bad+1)); fi
  run_score "$helper" "L" 0 $'=== RUN   TestX\n--- PASS: TestX (0.00s)\nPASS\nok  \tnowhereagent\t0.4s'
  if [ "$CASE_RC" -ne 1 ] || [[ "$CASE_OUT" != '  SURVIVED  L'* ]]; then echo "FAIL (j) survivor: want SURVIVED and status 1, got rc=$CASE_RC"; bad=$((bad+1)); fi
  if [[ "$CASE_OUT" != *$'\nok  \tnowhereagent\t0.4s' ]]; then echo "FAIL (j) survivor: the run's last line is not printed"; bad=$((bad+1)); fi
  run_score "$helper" "L" 2 $'FAIL\tnowhereagent [build failed]'
  if [ "$CASE_RC" -ne 1 ] || [[ "$CASE_OUT" != '  BROKEN    L -- the mutant did not compile'* ]]; then echo "FAIL (k) build failure: want BROKEN ... did not compile and status 1, got rc=$CASE_RC '$CASE_OUT'"; bad=$((bad+1)); fi
  run_score "$helper" "L" 1 $'signal: killed\nFAIL\tnowhereagent\t600.1s'
  if [ "$CASE_RC" -ne 1 ] || [[ "$CASE_OUT" != '  BROKEN    L'*'no ok line and no --- FAIL line'* ]]; then echo "FAIL (l) killed: want BROKEN with the no-line sentence and status 1, got rc=$CASE_RC '$CASE_OUT'"; bad=$((bad+1)); fi
  if [[ "$CASE_OUT" != *$'\nsignal: killed\nFAIL\tnowhereagent\t600.1s' ]]; then echo "FAIL (l) killed: the run's tail is not printed"; bad=$((bad+1)); fi
  run_score "$helper" "L" 1 $'panic: test timed out after 10m0s\nFAIL\tnowhereagent\t600.1s'
  if [ "$CASE_RC" -ne 1 ] || [[ "$CASE_OUT" != '  BROKEN    L'*'no ok line and no --- FAIL line'* ]]; then echo "FAIL (m) timeout: want BROKEN with the no-line sentence and status 1, got rc=$CASE_RC '$CASE_OUT'"; bad=$((bad+1)); fi
  big=$(printf -- '--- FAIL: TestX (0.01s)\n'; printf 'filler line of output %05d\n' $(seq 1 12000))
  run_score "$helper" "L" 1 "$big"
  if [ "${#big}" -lt 300000 ]; then echo "FAIL (n) control: the big output is only ${#big} bytes"; bad=$((bad+1)); fi
  if [ "$CASE_RC" -ne 0 ] || [ "$CASE_OUT" != "  convicted L" ]; then echo "FAIL (n) big output: want convicted and status 0, got rc=$CASE_RC"; bad=$((bad+1)); fi
  run_score "$helper" "L" 0 $'a log line saying\n--- FAIL: TestX (expected, subtest)\nok  \tnowhereagent\t0.4s'
  if [ "$CASE_RC" -ne 1 ] || [[ "$CASE_OUT" != '  SURVIVED  L'* ]]; then echo "FAIL (o) rc 0 with a --- FAIL text: want SURVIVED and status 1, got rc=$CASE_RC"; bad=$((bad+1)); fi

  for s in "${SUITES[@]}"; do
    f="$dir/$s.sh"
    if [ ! -f "$f" ]; then echo "FAIL (e) $s.sh is missing"; bad=$((bad+1)); continue; fi
    if ! grep -qxF '. ./suite-report.sh' "$f"; then echo "FAIL (e) $s.sh does not source suite-report.sh"; bad=$((bad+1)); fi
    if ! grep -qxF 'report_plain_run "$rc" "$out" || exit 1' "$f"; then echo "FAIL (e) $s.sh does not call report_plain_run"; bad=$((bad+1)); fi
  done
  for f in "$dir"/test-*.sh; do
    n=$(basename "$f" .sh)
    [ "$n" = test-suite-report ] && continue
    files=$((files+1))
    hits=$(grep -nE "$PIPEQ" "$f" || true)
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [[ "$line" =~ ^[0-9]+:[[:space:]]*# ]] && continue
      echo "FAIL (e) $n.sh pipes a variable into grep -q: $line"; bad=$((bad+1))
    done <<<"$hits"
    t=0; for s in "${TEMPMAKERS[@]}"; do [ "$s" = "$n" ] && t=1; done
    [ "$t" -eq 1 ] && continue
    hits=$(grep -nE '"\$out"[[:space:]]*\|[[:space:]]*tail -5|tail -5[[:space:]]*<<<[[:space:]]*"\$out"' "$f" || true)
    if [ -n "$hits" ]; then echo "FAIL (e) $n.sh sends \$out into a bare tail -5: $hits"; bad=$((bad+1)); fi
  done
  for s in "${MUTSUITES[@]}"; do
    f="$dir/$s.sh"
    if [ ! -f "$f" ]; then echo "FAIL (e) $s.sh is missing"; bad=$((bad+1)); continue; fi
    if ! grep -qxF '. ./suite-report.sh' "$f"; then echo "FAIL (e) $s.sh does not source suite-report.sh"; bad=$((bad+1)); fi
    if ! grep -qF 'score_mutant "' "$f"; then echo "FAIL (e) $s.sh does not score its mutants through score_mutant"; bad=$((bad+1)); fi
  done
  if [ "$files" -lt 30 ]; then echo "FAIL (e) control: the sweep read only $files suites"; bad=$((bad+1)); fi
  return "$bad"
}

report=$(check_all "$HERE/suite-report.sh" "${SUITE_DIR:-$HERE}"); bad=$?
[ -z "$report" ] || printf '%s\n' "$report"
if [ "$bad" -ne 0 ]; then echo "FAILED ($bad checks)"; exit 1; fi
echo "ALL CHECKS PASS"
[ "${1:-}" = --mutate ] || exit 0

fails=0
convict() { # convict <label> <helper> <suite_dir> <original-file> <mutated-file>
  local out rc
  if cmp -s "$4" "$5"; then echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; fi
  out=$(check_all "$2" "$3"); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; fails=$((fails+1)); else echo "  convicted $1"; fi
}
mutate_file() { # mutate_file <file> <sed-expr>
  sed -i -e "$2" "$1"
}

cp "$HERE/suite-report.sh" "$W/orig.sh"

cp "$W/orig.sh" "$W/m1.sh"; mutate_file "$W/m1.sh" 's|^  printf .%s\\n. "\$out"$|  tail -5 <<<"$out"|'
convict "M1 red branch prints only the tail" "$W/m1.sh" "$HERE" "$W/orig.sh" "$W/m1.sh"

cp "$W/orig.sh" "$W/m2.sh"; mutate_file "$W/m2.sh" 's|^    echo "FAILED with no --- FAIL line.*|    :|'
convict "M2 the no-FAIL-line sentence dropped" "$W/m2.sh" "$HERE" "$W/orig.sh" "$W/m2.sh"

cp "$W/orig.sh" "$W/m3.sh"; mutate_file "$W/m3.sh" 's|^  return 1$|  return 0|'
convict "M3 red branch returns 0" "$W/m3.sh" "$HERE" "$W/orig.sh" "$W/m3.sh"

mkdir "$W/suites"; cp "$HERE"/test-*.sh "$HERE/suite-report.sh" "$W/suites/"
cp "$W/suites/test-bound-budget.sh" "$W/orig-suite.sh"
python3 - "$W/suites/test-bound-budget.sh" <<'PY' || { echo "  INERT     M4 -- the revert did not apply"; fails=$((fails+1)); }
import sys
p = sys.argv[1]
s = open(p).read()
old = 'report_plain_run "$rc" "$out" || exit 1\n'
if s.count(old) != 1: sys.exit(1)
open(p, 'w').write(s.replace(old, 'echo "$out" | tail -5\n[ $rc -eq 0 ] || { echo FAILED; exit 1; }\n'))
PY
convict "M4 a converted suite back to the bare tail" "$HERE/suite-report.sh" "$W/suites" "$W/orig-suite.sh" "$W/suites/test-bound-budget.sh"
cp "$W/orig-suite.sh" "$W/suites/test-bound-budget.sh"   # S5 must be convicted by the pipe sweep alone

sm_mutant() { # sm_mutant <n> <label> <sed-expr>: a copy of the helper with its score_mutant changed
  cp "$W/orig.sh" "$W/s$1.sh"; sed -i -e "/^score_mutant()/,\$ $3" "$W/s$1.sh"
  convict "$2" "$W/s$1.sh" "$HERE" "$W/orig.sh" "$W/s$1.sh"
}
sm_mutant 1 "S1 score_mutant always returns 0" 's/return 1/return 0/'
sm_mutant 2 "S2 the rc check of the conviction dropped" 's/if \[ "\$rc" -ne 0 \] \&\& \[\[/if [[/'
sm_mutant 3 "S3 the BROKEN no-line arm folded into SURVIVED" 's/^  if \[ "\$rc" -eq 0 \] \&\& {.*; then$/  if true; then/'
sm_mutant 4 "S4 the tail of the run not printed" 's/^  tail -n 15 <<<"\$out"$/  :/'

cp "$W/suites/test-logout-wallet.sh" "$W/orig-wallet.sh"
python3 - "$W/suites/test-logout-wallet.sh" <<'PY' || { echo "  INERT     S5 -- the revert did not apply"; fails=$((fails+1)); }
import sys
p = sys.argv[1]
s = open(p).read()
old = '  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))\n'
if s.count(old) != 1: sys.exit(1)
new = '  echo "$res" | grep -q -- ' + chr(39) + '--- FAIL' + chr(39) + ' && echo "  convicted $1"\n'
open(p, 'w').write(s.replace(old, new))
PY
convict "S5 a mutant suite back to the piped grep -q" "$HERE/suite-report.sh" "$W/suites" "$W/orig-wallet.sh" "$W/suites/test-logout-wallet.sh"

if [ "$fails" -ne 0 ]; then echo "MUTANTS NOT ALL CONVICTED ($fails)"; exit 1; fi
echo "ALL 9 MUTANTS CONVICTED"
