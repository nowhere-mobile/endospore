#!/usr/bin/env bash
# test-ctap-uv-wire.sh [--mutate] -- runs ctap_uv_wire_test.go and ctap_getinfo_test.go (NWP-20261025-08), the built-in UV
# enrol, assert and slot loop against the simulated authenticator; --mutate re-runs them with each load-bearing rule of
# ctap_cmd.go, fido2.go and main.go broken in turn (since NWP-20261113-09 also assertAnySlot's stop at a dead USB link or
# a missing key, and its next slot after any other error). Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure. Nothing is left behind: one temp root holds the .orig copies and Go's temp dir, and the one
# EXIT trap restores both files and removes it, on a pass, a failed check or --mutate.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
FILES=(ctap_cmd.go fido2.go main.go)
trap 'for f in "${FILES[@]}"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestCtapUVWire_|TestCtapGetInfo_' -v .)

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
mut "V1 the enrol's getAssertion reuses the makeCredential token" ctap_cmd.go 'ga, err := getPinUvAuthToken\(h, info, nil, permGA, nowhereRPID\)' 'ga, err := mc, error(nil)'
mut "V2 the built-in enrol records uv=false" ctap_cmd.go 'return credID, salt, hmacOut, true, nil' 'return credID, salt, hmacOut, false, nil'
mut "V3 a key without built-in UV is not refused" ctap_cmd.go 'if m, cerr := chooseUV\(info\); cerr != nil \|\| m != uvBuiltIn \{' 'if m, cerr := chooseUV(info); false && (cerr != nil || m != uvBuiltIn) {'
mut "V4 the alwaysUv condition inverted" ctap_cmd.go 'if !always \{' 'if always {'
mut "V5 assertAnySlot drops the slot's uv" fido2.go 'fido2KeyAssertFn\(credID, salt, s\.UV\)' 'fido2KeyAssertFn(credID, salt, false)'
mut "V6 fido2-enroll records a literal false" main.go 'hex\.EncodeToString\(h\), uv, "usb"' 'hex.EncodeToString(h), false, "usb"' 'credID, salt, h, uv, err := fido2KeyEnroll\(\)' 'credID, salt, h, uv, err := fido2KeyEnroll()
		_ = uv'
mut "V7 fido2AssertOn ignores uv" ctap_cmd.go 'if !uv \{\n\t\treturn getAssertionHMAC\(' 'if !uv || true {
		return getAssertionHMAC('
mut "V8 enrollRefusal no longer refuses alwaysUv" ctap_cmd.go 'if v, ok := i\.option\("alwaysUv"\); ok && v \{' 'if v, ok := i.option("alwaysUv"); ok && v && false {'
mut "V9 assertAnySlot goes past a dead link" fido2.go 'if errors\.As\(err, &le\) \|\| ' 'if false && errors.As(err, &le) || '
mut "V10 assertAnySlot goes past a missing key" fido2.go '\|\| errors\.Is\(err, errNoFidoHidraw\) \{' '|| false && errors.Is(err, errNoFidoHidraw) {'
mut "V11 assertAnySlot stops at every error" fido2.go 'if errors\.As\(err, &le\) \|\| errors\.Is\(err, errNoFidoHidraw\) \{' 'if _ = le; err != nil {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
