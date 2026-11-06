#!/usr/bin/env bash
# test-ctap-getinfo.sh [--mutate] -- runs ctap_getinfo_test.go (NWP-20261022-09), the authenticatorGetInfo probe both enrol
# paths consult before the first touch; --mutate re-runs it against ctap_cmd.go / fido2_nfc.go with each rule broken in
# turn, restoring the files on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure. The suite creates no files: the mutants are applied in place, with the .orig copies restored by
# the EXIT trap.
set -uo pipefail
cd "$(dirname "$0")"
CMD=ctap_cmd.go; NFC=fido2_nfc.go
RUN=(go test -count=1 -run 'TestCtapGetInfo_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
grep -E '^(--- |ok|FAIL|PASS)' <<<"$out" | tail -25
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

for f in "$CMD" "$NFC"; do cp "$f" "$f.orig"; done
trap 'for f in "$CMD" "$NFC"; do mv -f "$f.orig" "$f"; done' EXIT
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local res f
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
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
  for f in "$CMD" "$NFC"; do cp "$f.orig" "$f"; done
}
mut "M1 enrollRefusal not consulted" "$CMD" 'if err := enrollRefusal\(info\); err != nil \{' 'if err := enrollRefusal(info); err != nil && false {'
mut "M2 alwaysUv refused when absent" "$CMD" 'option\("alwaysUv"\); ok && v' 'option("alwaysUv"); !ok || v'
mut "M3 fail-closed on a getInfo error" "$CMD" 'if info, err := ctapGetInfo\(h\); err == nil \{\n\t\tif err := enrollRefusal' 'info, err := ctapGetInfo(h)
	if err != nil {
		return nil, err
	}
	{
		if err := enrollRefusal'
mut "M4 protocol-1 membership inverted" "$CMD" '!i\.hasProtocol\(1\)' 'i.hasProtocol(1)'
mut "M5 NFC enrol back on bare makeCredential" "$NFC" 'enrollMakeCredential\(n, nowhereRPID\)' 'makeCredential(n, nowhereRPID)'
mut "M6 fido2EnrollOn skips the refusal" "$CMD" 'if rerr := enrollRefusal\(info\); rerr != nil \{' 'if rerr := enrollRefusal(info); rerr != nil && false {'
mut "M7 the 0x27 text reverted" "$CMD" 'if status == 0x27 \{' 'if false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
