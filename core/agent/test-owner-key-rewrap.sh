#!/usr/bin/env bash
# test-owner-key-rewrap.sh [--mutate] -- runs owner_key_rewrap_test.go (NWP-20261021-11); --mutate re-runs it against
# owner_key.go / telephony_owner.go with each part of OWNER-KEY-REWRAP broken in turn, restoring both files on exit.
# Each mutant must be CONVICTED by a test failure; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
RUN=(go test -count=1 -run 'TestOwnerKeyRewrap_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | tail -5
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d)
cp owner_key.go "$W/owner_key.go"
cp telephony_owner.go "$W/telephony_owner.go"
trap 'cp -f "$W/owner_key.go" owner_key.go; cp -f "$W/telephony_owner.go" telephony_owner.go; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local f=$2 res
  python3 - "$f" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$f" "$f"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp -f "$W/$f" "$f"
}
mut "M1 REWRAP writes v1 under the new passphrase only" owner_key.go \
  'body := ownerKeyFileBodyV2\(pub, f\.pepper, ownerWrap\{salt, wrap\(kek, priv\)\}, f\.wraps\(\)\[i\]\)' \
  'body := ownerKeyFileBody(pub, f.pepper, salt, wrap(kek, priv)); _ = i'
mut "M2 ENSURE that opens a v2 file's old wrapping prunes to it" owner_key.go \
  '(\tif i > 0 \{\n[^\n]*\n[^\n]*\n[^\n]*\n)\t\treturn "OK"\n' \
  '\1\t\tif err := ownerKeyWrite(ownerKeyFileBody(pub, f.pepper, f.old.salt, f.old.wrapped)); err != nil {\n\t\t\treturn ownerKeyIOErr(err)\n\t\t}\n\t\treturn "REPAIRED"\n'
mut "M3 ENSURE that opens the new wrapping keeps v2" owner_key.go \
  '\t\tif err := ownerKeyWrite\(ownerKeyFileBody\(pub, f\.pepper, f\.salt, f\.wrapped\)\); err != nil \{\n\t\t\treturn ownerKeyIOErr\(err\)\n\t\t\}\n\t\townerKeyLog\("pruned the old wrapping"\)\n\t\treturn "REPAIRED"' \
  '\t\treturn "OK"'
mut "M4 ownerKeyFromRequest tries the first wrapping only" telephony_owner.go \
  'ownerKeyOpenAny\(f\.wraps\(\), pass, pepper\)' \
  'ownerKeyOpenAny(f.wraps()[:1], pass, pepper)'
mut "M5 REWRAP mints a new keypair" owner_key.go \
  '(\tdefer clear\(priv\)\n\tsalt := randBytes\(ownerSaltLen\)\n\tkek := kekOwner\(newPass)' \
  '\tpub, priv, _ = newTelephonyKeypair()\n\1'
mut "M6 the mode check removed" owner_key.go \
  'if ownerPepperMode\(oldPepper\) != f\.pepper \|\| ownerPepperMode\(newPepper\) != f\.pepper \{' \
  'if false {'
mut "M7 WRONG falls through to a replace" owner_key.go \
  '(ownerKeyLog\("rewrap refused \(did not open\)"\)\n)\t\treturn "WRONG"' \
  '\1\t\tif err := ownerKeyMint(newPass, newPepper); err != nil {\n\t\t\treturn ownerKeyIOErr(err)\n\t\t}\n\t\treturn "OK"'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
