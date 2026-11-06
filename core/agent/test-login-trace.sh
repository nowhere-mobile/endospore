#!/usr/bin/env bash
# test-login-trace.sh [--mutate] -- NWP-20261030-08: storeTrace.split's cap/store/kdf/other rendering and the other-time
# clamp, since's per-field difference and the distinct-head counter (nil-safe, reset on Begin, nil after End). Runs the
# focused Go tests; --mutate applies each mutant to a pristine copy of login_trace.go (restored on exit) and requires a
# real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp login_trace.go "$W/login_trace.go.orig" || exit 2
trap 'cp "$W/login_trace.go.orig" login_trace.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="LoginTrace"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" body="$2" o
  cp "$W/login_trace.go.orig" login_trace.go
  if ! python3 -c "
s = open('login_trace.go').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('login_trace.go','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); cp "$W/login_trace.go.orig" login_trace.go; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  cp "$W/login_trace.go.orig" login_trace.go
}
echo "== mutations =="
mutate "T1: the other < 0 clamp is removed" "
t = s.replace('\tif other < 0 {\n\t\tother = 0\n\t}\n', '', 1)"
mutate "T2: the ms divisor is 1e3, not 1e6" "
t = s.replace('return ns / 1e6 }', 'return ns / 1e3 }', 1)"
mutate "T3: split prints getN where it should print capN" "
t = s.replace('d.capN, ms(d.capNs)', 'd.getN, ms(d.capNs)', 1)"
mutate "T4: since subtracts capN in the wrong order" "
t = s.replace('a.capN - b.capN', 'b.capN - a.capN', 1)"
mutate "T5: traceDistinctEnd returns (distinct, total)" "
t = s.replace('\ttraceDistinctMu.Unlock()\n\treturn\n}', '\ttraceDistinctMu.Unlock()\n\treturn distinct, total\n}', 1)"
mutate "T6: traceDistinctEnd no longer sets the map to nil" "
t = s.replace('\ttraceDistinct = nil\n', '', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "6 mutants convicted"
