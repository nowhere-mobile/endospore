#!/usr/bin/env bash
# test-coldlock-abandoned.sh [--mutate] -- runs coldlock_abandoned_test.go (NWP-20261109-04); --mutate re-runs it
# against main.go with the cold lock's wait for an abandoned RW op broken in turn, restoring the file on exit. Each
# mutant must be CONVICTED (a real `--- FAIL`); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestColdLockAbandoned' .)

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
  if [[ "$mout" == *'[build failed]'* || "$mout" == *'[setup failed]'* ]]; then
    echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  elif [ $mrc -ne 0 ] && [[ "$mout" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1 (rc=$mrc, no --- FAIL)"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "M1 the wait not called by coldLockTeardown" '\tif held \{\n\t\tcoldLockWaitAbandoned\(bell, revokedNow, tWait\)\n\t\}\n' ''
mut "M2 the revoked() check removed" '\t\tif revoked\(\) \{\n\t\t\toutcome = "revoked"\n\t\t\treturn outcome\n\t\t\}\n' ''
mut "M3 coldLockWaitFor never published" '\tcoldLockWaitFor\.Store\(tok\)\n' ''
mut "M4 the raw op published" 'coldLockWaitFor\.Store\(tok\)' 'coldLockWaitFor.Store(op)'
mut "M5 a stopped instance does not end the wait" '(\t\tif )!running\(\)( \{\n\t\t\toutcome = "stopped")' '\1false\2'
mut "M6 the status precedence reversed" '(\t\top, _ := )coldLockWaitFor(\.Load\(\)\.\(string\)\n\t\tif op == "" \{\n\t\t\top, _ = )rwHolderOp(\.Load\(\)\.\(string\))' '\1rwHolderOp\2coldLockWaitFor\3'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
