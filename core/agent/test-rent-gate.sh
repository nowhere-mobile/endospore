#!/usr/bin/env bash
# test-rent-gate.sh [--mutate] -- runs the rent-gate cases (rent_gate_test.go; NWP-20261026-12); --mutate re-runs them
# against a COPY of the package with each guard broken in turn. Each mutant must be CONVICTED by a real `--- FAIL`;
# one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
TESTS='TestRentGate|TestRestartUnsaved_BusyWhileRentIsPaid|TestEndUnsaved_BusyWhileRentIsPaid|TestMaybePayRent_Skips'

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
grep -E '^(--- |ok|FAIL|PASS)' <<<"$out" | tail -20
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

P="$W/agent"
cp -a . "$P" || exit 2
fails=0
mut() { # mut <label> <file> <regex> <replacement> [dotall]: exactly one substitution of <regex> in <file>, or it is INERT
  local label=$1 file=$2 res
  cp -f "$P/$file" "$W/orig" || return 1
  python3 - "$P/$file" "$3" "$4" "${5:-}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re, sys
p, pat, repl, flag = sys.argv[1:5]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1, flags=re.S if flag else 0)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/orig" "$P/$file"
}

mut "M1 beginRent ignores the exit hold" rent_gate.go '\tif rentExitHold \{' '	if false && rentExitHold {'
mut "M2 holdRentForExit ignores a running spend" rent_gate.go '(func holdRentForExit\(\) bool \{.*?)if rentInFlight > 0 \{' '\1if false && rentInFlight > 0 {' dotall
mut "M3 RESTART-UNSAVED takes no hold" end_unsaved.go '\tif !holdRentForExit\(\) \{\n[^\n]*restart-unsaved user %s: BUSY -- a rent payment[^\n]*\n[^\n]*\n\t\treturn\n\t\}\n' ''
mut "M4 END-UNSAVED takes no hold" end_unsaved.go '\tif !holdRentForExit\(\) \{\n[^\n]*end-unsaved user %s: BUSY -- a rent payment[^\n]*\n[^\n]*\n\t\treturn\n\t\}\n' ''
mut "M5 maybePayRent never asks the gate" main.go '\tif !beginRent\(\) \{\n[^\n]*\n\t\treturn\n\t\}\n\tdefer endRent\(\)\n' ''
mut "M6 beginRent ignores a pending restart" rent_gate.go '\tif restartPending\(\) \{' '	if false && restartPending() {'
mut "M7 RESTART-UNSAVED never releases the hold" end_unsaved.go '\tdefer releaseRent\(\) //[^\n]*restartPending[^\n]*\n' ''
mut "M8 maybePayRent spends from an ended session" main.go '\tif n, _, _ := readRoamSession\(dest\); n != name \|\| isLocalSession\(dest\) \{\n[^\n]*\n\t\treturn\n\t\}\n' ''
[ "$fails" -eq 0 ] && echo "== all 8 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
