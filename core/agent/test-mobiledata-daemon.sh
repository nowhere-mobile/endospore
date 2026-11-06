#!/usr/bin/env bash
# test-mobiledata-daemon.sh [--mutate] -- runs the daemon's half of session-scoped mobile data (mobiledata_test.go) with
# the location suites it mirrors (NWP-20261026-06); --mutate re-runs them against copies of main.go,
# roamsession_marker.go and mobiledata.go with each claim, release and guard broken in turn, restoring the files on
# exit. Each mutant must be CONVICTED (a `--- FAIL`); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
FILES=(main.go roamsession_marker.go mobiledata.go)
RUN=(go test -count=1 -run 'MobileData|LocGlobals|ApplyLocation|LocClaim|RefusedResume|ConcurrentSafe' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
trap 'for f in "${FILES[@]}"; do cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local mout mrc f
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1); mrc=$?
  if [ $mrc -ne 0 ] && [[ "$mout" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1 (rc=$mrc, no --- FAIL)"; fails=$((fails+1)); fi
  for f in "${FILES[@]}"; do cp "$W/$f.orig" "$f"; done
}
mut "D1 the resume claim removed" main.go '\tclaimMobileDataAsync\(dest, uid, "resume"\)[^\n]*\n' ''
mut "D2 the offline claim removed" main.go '\tclaimMobileDataAsync\(dest, uid, "offline"\)\n' ''
mut "D3 the signout release removed" main.go '\t*releaseMobileDataAsync\(dest, au, "signout"\)[^\n]*\n' ''
mut "D4 the cold-lock release moved after the switch is published" main.go \
  '\treleaseMobileDataAtLock\(dest, uid\)[^\n]*\n(.*?pendingLockUID = uid[^\n]*\n\tpendingReapMu\.Unlock\(\)\n)' \
  '\1\treleaseMobileDataAtLock(dest, uid)\n'
mut "D5 the gone release removed" roamsession_marker.go '\treleaseMobileDataAsync\(dest, uid, "gone"\)[^\n]*\n' ''
mut "D6 runWorkerHeld re-checks locapply only" main.go 'op == "locapply" \|\| op == "mdapply"' 'op == "locapply"'
mut "D7 the verb skips sessionCaller" mobiledata.go 'uid == "" \|\| !sessionCaller\(conn, uid\)' 'uid == ""'
mut "D8 the verb passes the raw worker reply" mobiledata.go 'locReplyToken\(claimMobileData\(dest, uid, "live"\)\)' 'claimMobileData(dest, uid, "live")'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
