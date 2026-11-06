#!/usr/bin/env bash
# test-signout-signal.sh [--mutate] -- runs the sign-out signal cases (signout_signal_test.go; NWP-20261109-12, Q116);
# --mutate re-runs them against logout_wait.go / main.go broken in turn, restoring both on exit. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'for f in main.go logout_wait.go; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -timeout 60s -run 'SignOutSignal' -v .) # a hang is a failure, never a ten-minute wait

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp logout_wait.go "$W/logout_wait.go.orig"
fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 f=$2 res
  python3 - "$f" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$f.orig" "$f"; return; }
import sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  # A timeout or a panic is not a conviction, whatever `--- FAIL` lines came before it: the run did not finish.
  if grep -qE 'panic: test timed out|^panic: ' <<<"$res"; then echo "  HUNG      $label -- the run timed out or panicked"; fails=$((fails+1))
  elif grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$f.orig" "$f"
}
RAISE='\tsignOutRaise(dest)\n'
LOWER='\tdefer signOutLower(dest) // runs after the lock is held, on every return below\n'
TRY='\tif sessionMu.TryLock() {\n\t\treturn\n'
FRESH='\tsignOutC = make(chan struct{})\n'
START='\tos.Remove(filepath.Join(dest, odCancelFile))\n'
mut "M1 the raise removed" logout_wait.go \
  "s.replace('$RAISE', '', 1) if s.count('$RAISE') == 1 else None"
mut "M2 the lower removed" logout_wait.go \
  "s.replace('$LOWER', '', 1) if s.count('$LOWER') == 1 else None"
mut "M3 the raise on the TryLock-succeeds path too" logout_wait.go \
  "s.replace('$TRY', '\tif sessionMu.TryLock() {\n\t\tsignOutRaise(dest)\n\t\treturn\n', 1) if s.count('$TRY') == 1 else None"
mut "M4 the channel never replaced at lower" logout_wait.go \
  "s.replace('$FRESH', '', 1) if s.count('$FRESH') == 1 else None"
mut "M5 the start-up removal removed" main.go \
  "s.replace('$START', '', 1) if s.count('$START') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
