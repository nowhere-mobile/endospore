#!/usr/bin/env bash
# test-logoff-watchdog-supersede.sh [--mutate] -- runs the TestLogoffWatchdog_* cases of logoff_cutoff_test.go
# (NWP-20261017-12); --mutate re-runs them against main.go with each guard broken in turn, restoring the file on
# exit. Each mutant must be CONVICTED (a --- FAIL); one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestLogoffWatchdog_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  cp "$MAIN.orig" "$MAIN"
}
mut "M1 the unstick re-check removed" '(pendingReapMu\.Lock\(\)\n\t\t\tif )logoffSuperseded\(uid, logoffClaim\)( \{ // NWP-20261017-12)' '\1false\2'
mut "M2 return becomes continue on the tick check" '(if superseded \{\n\t\t\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] logoff stall watchdog: superseded by a retry, exiting\\n"\)\n\t\t\t\t)return' '\1continue'
mut "M3 the tick supersede check removed" 'superseded := logoffSuperseded\(uid, logoffClaim\)' 'superseded := false'
mut "M4 the tick check asks with the wrong claim" 'superseded := logoffSuperseded\(uid, logoffClaim\)' 'superseded := logoffSuperseded(uid, logoffClaim+1)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
