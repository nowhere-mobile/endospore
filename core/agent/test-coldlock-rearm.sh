#!/usr/bin/env bash
# test-coldlock-rearm.sh [--mutate] -- runs coldlock_rearm_test.go (NWP-20261031-02); --mutate re-runs it against main.go
# with each guard of the REARM phase broken in turn, restoring the file on exit. Each mutant must be CONVICTED (a real
# `--- FAIL`); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestColdLockRearm' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

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
  local mout mrc
  mout=$("${RUN[@]}" 2>&1); mrc=$?
  if [ $mrc -ne 0 ] && [[ "$mout" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1 (rc=$mrc, no --- FAIL)"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "R1 the Check B call deleted" '\t\tif why == "logoff in flight" \{\n\t\t\tqueueIdleRearm\(uid\)[^\n]*\n\t\t\}\n' ''
mut "R2 REARM handed out before LOCK" '(\tif pendingLockUID != "" \{.*?\n\t\}\n)(\tif pendingRearmUID != "" \{.*?\n\t\}\n)' '\2\1'
mut "R3 the REARM ack ignores the uid" 'if pendingRearmUID == uid \{' 'if true {'
mut "R4 the call also on the user-present arm" '(\t\trelease\(\)\n)(\t\tif why == "logoff in flight" \{)' '\1\t\tqueueIdleRearm(uid)\n\2'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
