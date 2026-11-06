#!/usr/bin/env bash
# test-doze-arm.sh [--mutate] -- runs the daemon's half of the unarmed-session mark (dozearm_test.go, NWP-20261117-06,
# dn-1023 #3) with the verb parse and the lock-free list, then `go vet ./...`; --mutate re-runs the tests against copies
# of main.go and dozearm.go with each guard broken in turn, restoring the files on exit. Each mutant must be CONVICTED
# (a `--- FAIL`); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
FILES=(main.go dozearm.go)
RUN=(go test -count=1 -run 'TestDozeArm|TestDaemonVerbs|TestConcurrentSafeCmd' .)

W=$(mktemp -d) || exit 2
for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
trap 'for f in "${FILES[@]}"; do cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
if [ "${1:-}" != --mutate ]; then
  vout=$(go vet ./... 2>&1); vrc=$?
  if [ "$vrc" -ne 0 ]; then printf '%s\n' "$vout"; echo "FAILED: go vet ./..."; exit 1; fi
  echo "go vet ./...: ok"
  exit 0
fi

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local mout mrc f
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$mout" || fails=$((fails+1))
  for f in "${FILES[@]}"; do cp "$W/$f.orig" "$f"; done
}
mut "M1 the DENIED check removed" dozearm.go 'if !ownerCallerOK\(ownerPeerUID\(conn\)\) \{' 'if false {'
mut "M2 UNARMED answered for any uid" dozearm.go 'unarmed := dozeUnarmed\[uid\]' \
  'unarmed := func() bool { for _, v := range dozeUnarmed { if v { return true } }; return false }()'
mut "M3 one slot for every uid" dozearm.go 'dozeUnarmed\[uid\] = mode == "unarmed"' \
  'dozeUnarmed = map[string]bool{uid: mode == "unarmed"}'
mut "M4 the verbs taken off concurrentSafeCmd" main.go '\t\t"DOZE-ARM", "GET-DOZE-ARM",\n' ''
mut "M5 GET-DOZE-ARM skips sessionCaller" dozearm.go 'uid == "" \|\| !sessionCaller\(conn, uid\)' 'uid == ""'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
