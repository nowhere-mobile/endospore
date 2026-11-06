#!/usr/bin/env bash
# test-ctap-cmd.sh [--mutate] -- runs ctap_cmd_test.go (NWP-20261022-07), the CTAP2 command layer against a simulated
# authenticator; --mutate re-runs it against ctap_cmd.go with each load-bearing rule broken in turn, restoring the file
# on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
# The suite creates no files: the mutants are applied in place, with ctap_cmd.go.orig restored by the EXIT trap.
set -uo pipefail
cd "$(dirname "$0")"
F=ctap_cmd.go
RUN=(go test -count=1 -run 'TestCtapCmd_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
grep -E '^(--- |ok|FAIL|PASS)' <<<"$out" | tail -25
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$F.orig"
trap 'mv -f "$F.orig" "$F"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl>
  python3 - "$F" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$F.orig" "$F"
}
mut "M1 a 0x34 no longer retried" '\t\t\tcontinue\n' ''
mut "M2 retry bound of 1" 'const maxAttempts = 4' 'const maxAttempts = 1'
mut "M3 getAssertion sends up:false" 'put\("up", true\)' 'put("up", false)'
mut "M4 makeCredential sends an options map" 'put\(uint64\(6\), newCBORMap\(\)\.put\("hmac-secret", true\)\)' 'put(uint64(6), newCBORMap().put("hmac-secret", true)).
		put(uint64(7), newCBORMap().put("rk", false))'
mut "M5 allowList carries the wrong credId" 'put\("id", credID\)' 'put("id", []byte("x"))'
mut "M6 hmac-secret output returned undecrypted" 'return pp\.hmacSecretOutput\(encOut\)' 'return encOut, nil'
mut "M7 one stale key agreement reused on retry" 'for attempt := 0; attempt < maxAttempts; attempt\+\+ \{\n\t\tauthPub, err := getKeyAgreement\(h\)\n\t\tif err != nil \{\n\t\t\treturn nil, err\n\t\t\}\n' 'authPub, err := getKeyAgreement(h)
	if err != nil {
		return nil, err
	}
	for attempt := 0; attempt < maxAttempts; attempt++ {
'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
