#!/usr/bin/env bash
# test-devtoggles-daemon.sh [--mutate] -- runs the daemon's half of session device toggles (devtoggles_test.go) with the
# location and mobile-data suites it mirrors (NWP-20261027-08); --mutate re-runs them against copies of main.go,
# roamsession_marker.go and devtoggles.go with each claim, release and guard broken in turn, restoring the files on
# exit. Each mutant must be CONVICTED (a `--- FAIL`); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
FILES=(main.go roamsession_marker.go devtoggles.go)
RUN=(go test -count=1 -run 'DevToggles|MobileData|LocGlobals|EveryGoroutine' .)
W=$(mktemp -d) || exit 2
trap 'for f in "${FILES[@]}"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

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
mut "Y1 the sign-in claim removed" main.go '\tclaimDevTogglesAsync\(dest, uid, "signin"\)[^\n]*\n' ''
mut "Y2 the resume claim removed" main.go '\tclaimDevTogglesAsync\(dest, uid, "resume"\)[^\n]*\n' ''
mut "Y3 the cold-lock release moved after the switch is published" main.go \
  '\treleaseDevTogglesAtLock\(dest, uid\)[^\n]*\n(.*?pendingLockUID = uid[^\n]*\n\tpendingReapMu\.Unlock\(\)\n)' \
  '\1\treleaseDevTogglesAtLock(dest, uid)\n'
mut "Y4 runWorkerHeld does not re-check dtclaim" main.go 'op == "mdapply" \|\| op == "dtclaim"' 'op == "mdapply"'
mut "Y5 the gone release removed" roamsession_marker.go '\treleaseDevTogglesAsync\(dest, uid, "gone"\)[^\n]*\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
