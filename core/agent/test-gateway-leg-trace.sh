#!/usr/bin/env bash
# test-gateway-leg-trace.sh [--mutate] -- NWP-20261203-14: a failed gateway leg of a store read (capReadURL) logs one
# line of fixed words and integers naming the stage its last request stopped in (gwleg_trace.go): stage, conn reuse,
# protocol, phase times, error class and streak, and never the error text, URL, host or ref. Runs the focused Go
# tests; --mutate applies each mutant to a pristine copy of main.go and gwleg_trace.go (both restored on exit) and
# requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
# Mutants: T1 the WroteRequest hook records nothing, T2 GotConn ignores Reused, T3 a success no longer resets the
# streak, T4 the line appends err.Error(), T5 capReadURL no longer calls .line(, T6 the ECONNREFUSED arm is gone,
# T7 a RoundTrip no longer clears the phases of the request before it, T8 a phase start no longer marks its phase
# active (a stalled fallback lookup reads as the refused connect before it).
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp gwleg_trace.go "$W/gwleg_trace.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/gwleg_trace.go.orig" gwleg_trace.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestGwLeg|TestCapGetFitsTheStallBudget|TestEveryGatewayCallSiteNamesABudget'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
restore() {
  cp "$W/main.go.orig" main.go
  cp "$W/gwleg_trace.go.orig" gwleg_trace.go
}
# mutate <label> <file> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" body="$3" o
  restore
  if ! python3 -c "
import sys
f = sys.argv[1]
s = open(f).read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)" "$f"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); restore; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  restore
}
echo "== mutations =="
mutate "T1: the WroteRequest hook records nothing (TestGwLegResponseWait reads request-write)" gwleg_trace.go "
t = s.replace('\t\t\t\t\tp.wrote = time.Now()\n', '\t\t\t\t\t_ = info\n', 1)"
mutate "T2: GotConn ignores Reused (TestGwLegReused)" gwleg_trace.go "
t = s.replace('p.reused = info.Reused', 'p.reused = false', 1)"
mutate "T3: a success no longer resets the streak (TestGwLegStreak)" gwleg_trace.go "
t = s.replace('\t\tgwLegFailStreak.Store(0)\n', '', 1)"
mutate "T4: the line appends err.Error() (TestGwLegPrivacy)" gwleg_trace.go "
t = s.replace('gwLegClass(err), n)\n', 'gwLegClass(err), n) + \" \" + err.Error()\n', 1)"
mutate "T5: capReadURL no longer calls .line( (TestGwLegWiredIntoCapReadURL)" main.go "
t = s.replace('\tif l := lt.line(err, elapsed); l != \"\" {\n\t\tfmt.Fprintln(os.Stderr, l)\n\t}\n', '\t_ = elapsed\n', 1)"
mutate "T6: the ECONNREFUSED arm is gone, a refused dial reads class=other (TestGwLegRefused)" gwleg_trace.go "
t = s.replace('case errors.Is(err, syscall.ECONNREFUSED):', 'case false:', 1)"
mutate "T7: a RoundTrip no longer clears the phases (TestGwLegClearPerRoundTrip reads answered)" gwleg_trace.go "
t = s.replace('\t\tt.p = gwLegPhases{}\n', '', 1)"
mutate "T8: a phase start no longer marks its phase active (TestGwLegFallbackDNS reads conn-wait)" gwleg_trace.go "
t = s.replace('\tp.active = phase\n', '', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "8 mutants convicted"
