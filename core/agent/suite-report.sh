#!/usr/bin/env bash
# suite-report.sh -- sourced by the agent test-*.sh suites (NWP-20261022-14): report_plain_run <rc> <output> prints a
# plain `go test` run. Green: the last five lines. Red: the WHOLE output, then every `--- FAIL` line (or a sentence
# saying there is none), then FAILED. A bare `tail -5` dropped the failing test's name whenever a later test or a
# leftover goroutine logged after it, and made an exited binary look like an assertion failure.
report_plain_run() { # report_plain_run <rc> <output>
  local rc="$1" out="$2" f
  if [ "$rc" -eq 0 ]; then tail -5 <<<"$out"; return 0; fi
  printf '%s\n' "$out"
  f=$(grep -- '--- FAIL' <<<"$out" || true)
  echo "== failing tests:"
  if [ -n "$f" ]; then
    printf '%s\n' "$f"
  else
    echo "FAILED with no --- FAIL line: the test binary exited (a panic, os.Exit or a timeout), or it did not build -- read the full output above"
  fi
  echo FAILED
  return 1
}

# score_mutant <label> <rc> <output> (NWP-20261110-03): the verdict of one --mutate run, for the nine suites that used to
# pipe the output into `grep -q`. Backlog row "test-catalog-rollback.sh --mutate scored mutant C2 SURVIVED once on main's CI,
# and convicted it 3 of 3 on re-runs". Two readings of that row: (1) `echo "$res" | grep -q '^--- FAIL'` under pipefail --
# grep -q leaves at its first match, the echo's next write gets SIGPIPE, the pipeline's status is 141 and the `if` is false
# although the line is there (load-sensitive); (2) a test binary that was killed, timed out or never started prints neither
# an ok line nor a --- FAIL line and was scored SURVIVED with nothing of its run shown. This matches on the captured string
# (no pipe, no subprocess), and a run with neither line is BROKEN, never a survivor.
score_mutant() {
  local label="$1" rc="$2" out="$3" nl=$'\n'
  if [ "$rc" -ne 0 ] && [[ "$nl$out" == *"$nl"*'--- FAIL'* ]]; then echo "  convicted $label"; return 0; fi
  if [[ "$out" == *'build failed'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; return 1; fi
  if [ "$rc" -eq 0 ] && { [[ "$nl$out" == *"${nl}ok "* ]] || [[ "$nl$out" == *"${nl}ok"$'\t'* ]]; }; then
    echo "  SURVIVED  $label"
  else
    echo "  BROKEN    $label -- the run ended with no ok line and no --- FAIL line (killed, timed out or did not start), rc=$rc"
  fi
  echo "    last lines of its run:"
  tail -n 15 <<<"$out"
  return 1
}
