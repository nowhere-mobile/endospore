#!/usr/bin/env bash
# test-ctap-uv.sh [--mutate] -- runs ctap_uv_test.go (NWP-20261025-07), the CTAP2 user-verification token and
# pinUvAuthParam against the simulated authenticator; --mutate re-runs it with each load-bearing rule of ctap_uv.go and
# ctap_cmd.go broken in turn. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure. Nothing is left behind: one temp root holds the .orig copies and Go's temp dir, and the one
# EXIT trap restores both files and removes it, on a pass, a failed check or --mutate.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
FILES=(ctap_uv.go ctap_cmd.go)
trap 'for f in "${FILES[@]}"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestCtapUV_|TestCtapCmd_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
grep -E '^(--- |ok|FAIL|PASS)' <<<"$out" | tail -30
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <regex pattern> <repl> [<pattern> <repl> ...]; every pair must apply exactly once
  local label=$1 file=$2 res f
  shift 2
  python3 - "$file" "$@" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p=sys.argv[1]; args=sys.argv[2:]
s=open(p).read()
for pat,rep in zip(args[0::2],args[1::2]):
    s,c=re.subn(pat,lambda m: rep,s,count=2,flags=re.S)
    if c!=1: sys.exit(1)
open(p,'w').write(s)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $label"
  elif [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  for f in "${FILES[@]}"; do cp "$W/$f.orig" "$f"; done
}
mut "U1 clientPin checked before uv" ctap_uv.go 'case uv && tok:\n\t\treturn uvBuiltIn, nil\n\tcase uv:\n\t\treturn 0, errBuiltInUVUnsupported\n\tcase pin:\n\t\treturn uvPIN, nil\n' 'case pin:
		return uvPIN, nil
	case uv && tok:
		return uvBuiltIn, nil
	case uv:
		return 0, errBuiltInUVUnsupported
'
mut "U2 built-in subCommand 0x06 -> 0x09" ctap_uv.go 'cpGetTokenUsingUV  = 0x06' 'cpGetTokenUsingUV  = 0x09'
mut "U3 permMC = 0x02" ctap_uv.go 'permMC uint64 = 0x01' 'permMC uint64 = 0x02'
mut "U4 param over a fresh random hash" ctap_uv.go 'mac\.Write\(clientDataHash\)' 'fresh := make([]byte, 32)
	rand.Read(fresh)
	mac.Write(fresh)'
mut "U5 makeCredentialTok drops key 0x08" ctap_cmd.go 'params\.put\(uint64\(8\), tok\.param\(clientDataHash\)\)\.put\(uint64\(9\), uint64\(1\)\)' 'params.put(uint64(9), uint64(1))'
mut "U6 getAssertionHMACTok drops key 0x07" ctap_cmd.go 'params\.put\(uint64\(6\), tok\.param\(clientDataHash\)\)\.put\(uint64\(7\), uint64\(1\)\)' 'params.put(uint64(6), tok.param(clientDataHash))'
mut "U7 token used undecrypted" ctap_uv.go 'tok, err := pp\.decrypt\(enc\)' 'tok, err := enc, error(nil)'
mut "U8 UV_BLOCKED falls through to the PIN" ctap_uv.go 'if errors\.Is\(err, errUVBlocked\) \{[^\n]*\n\t\t\treturn nil, err' 'if errors.Is(err, errUVBlocked) {
			return tokenUsingPIN(h, i, pin, perms, rpID)'
mut "U9 the PIN appended to the PIN_INVALID text" ctap_uv.go 'hashEnc, err = pp\.pinHashEnc\(p\); err != nil \{' 'hashEnc, err = pp.pinHashEnc(p); err != nil || (func() bool { leakedPIN = p; return false })() {' 'the key refused the PIN"\)' 'the key refused the PIN " + leakedPIN)' '\n// tokenStatusErr' '
var leakedPIN string

// tokenStatusErr'
mut "U10 token-mode 0x34 retried" ctap_cmd.go 'status == 0x34 && tok != nil' 'status == 0x34 && tok != nil && false'
mut "U11 uv without pinUvAuthToken takes the PIN path" ctap_uv.go 'case uv:\n\t\treturn 0, errBuiltInUVUnsupported' 'case uv && !pin:
		return 0, errBuiltInUVUnsupported'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
