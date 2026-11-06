#!/usr/bin/env bash
# test-signin-fail.sh [--mutate] -- runs signin_fail_test.go and the gate-only / lock-free pins SIGNIN-SHOWN joins
# (NWP-20261106-07, Q065); --mutate re-runs them against a COPY of the package with the failed-sign-in record broken in
# turn (the work tree is never edited). Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails
# to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=$PWD
PAT='SigninShown|SigninFail|InRunFacts|^TestGateOnly|^TestConcurrentSafeCmd$'

out=$(go test -count=1 -run "$PAT" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <python regex> <replacement>: exactly one match in a fresh copy of the package, or INERT.
mut() {
  local label="$1" file="$2" pat="$3" rep="$4" d res
  d=$(mktemp -d -p "$W") || exit 2
  cp -r "$SRC/." "$d/"
  if ! python3 - "$d/$file" "$pat" "$rep" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; fi
  res=$(cd "$d" && go test -count=1 -run "$PAT" . 2>&1)
  if [[ "$res" == *'[build failed]'* || "$res" == *'setup failed'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $label"
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  rm -rf "$d"
}

mut "S1 any code accepted" signin_fail.go '(func signinFailCode\(s string\) bool \{).*?\n\}\n' '\1\n\treturn s != ""\n}\n'
mut "S2 handleRoamIn's drop removed" main.go '(func handleRoamIn\(conn[^\n]*\n\t//[^\n]*\n)\tdropSigninFail\(dest\)\n' '\1'
mut "S3 facts attached to every code" signin_fail.go 'code == "load" && inRunHeld' 'inRunHeld'
mut "S4 SIGNIN-SHOWN out of concurrentSafeCmd" main.go '\t\t"SIGNIN-SHOWN",\n\t\t// GET-LOGOFF-REFUSAL' '\t\t// GET-LOGOFF-REFUSAL'
mut "S5 SIGNIN-SHOWN out of gateOnlyCmd" owner_key.go '"OTA-APPLY", "SIGNIN-SHOWN",' '"OTA-APPLY",'
mut "S6 merged at session scope" signin_fail.go 'if !deviceScope \|\| status == nil \{' 'if status == nil {'
mut "S7 hold computed as stall" signin_fail.go 'secs\(now\.Sub\(from\)\), secs\(now\.Sub\(t0\)\)' 'secs(now.Sub(from)), secs(now.Sub(from))'
mut "S8 handleRoamIn's drop after the OTA refusal" main.go '(func handleRoamIn\(conn[^\n]*\n)(\t//[^\n]*\n\tdropSigninFail\(dest\)\n)(\tif refuseSignInDuringOta\(conn, dest\) \{[^\n]*\n\t\treturn\n\t\}\n)' '\1\3\2'

[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
