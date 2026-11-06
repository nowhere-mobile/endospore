#!/usr/bin/env bash
# test-gate-caller.sh [--mutate] -- runs gate_caller_test.go (NWP-20261023-05); --mutate re-runs it against main.go and
# telephony_live_owned.go with the user-0 rule of GET-RELOGIN, GET-WIFI-MIRROR, WIFI-ADOPT and TEL-LIVE-OWNED broken in
# turn, restoring both files on exit. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails
# to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
TEL=telephony_live_owned.go
RUN=(go test -count=1 -run '^TestGateCaller_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$MAIN" "$W/main.go.orig"
cp "$TEL" "$W/tel.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; cp -f "$W/tel.go.orig" "$TEL" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/main.go.orig" "$MAIN"; cp "$W/tel.go.orig" "$TEL"; }
# conv <label>: run the suite against the mutated tree, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: TestGateCaller_'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <file> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$2" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
GUARD='if !gateCallerOK\(ownerPeerUID\(conn\)\) \{'
mut "M1 the ceiling raised past any roamed uid" "$MAIN" 'uid >= 0 && uid < 100000' 'uid >= 0 && uid < 10000000'
mut "M2 GET-RELOGIN not gated" "$MAIN" '(func handleGetRelogin\(.*?\n\t)'"$GUARD" '\1if false {'
mut "M3 GET-WIFI-MIRROR not gated" "$MAIN" '(func handleGetWifiMirror\(.*?\n\t)'"$GUARD" '\1if false {'
mut "M4 WIFI-ADOPT not gated" "$MAIN" '(func handleWifiAdopt\(.*?\n\t)'"$GUARD" '\1if false {'
mut "M5 TEL-LIVE-OWNED not gated" "$TEL" '(func handleTelLiveOwned\(.*?\n\t)'"$GUARD" '\1if false {'
mut "M6 the failed-read refusal dropped" "$MAIN" 'return uid >= 0 && uid < 100000' 'return uid < 100000'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
