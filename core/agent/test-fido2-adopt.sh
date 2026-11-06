#!/usr/bin/env bash
# test-fido2-adopt.sh [--mutate] -- runs fido2_adopt_test.go (NWP-20261111-03, Q016: the stranded phone's "Use your
# security key"); --mutate re-runs it against a COPY of the package with fido2_adopt.go broken in turn (the work tree
# is never edited). Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile,
# counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=$PWD
PAT='Fido2Adopt'

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

mut "M1 no verification after the assert" fido2_adopt.go 'fido2DKWith\(v, deriveKey\(name, pass\), h\) == nil' 'false'
mut "M2 verification accepts the pass rung" fido2_adopt.go 'fido2DKWith\(v, deriveKey\(name, pass\), h\) == nil' 'openVaultDK(v, name, pass) == nil'
mut "M3 spec staged before verification" fido2_adopt.go '(\tif fido2DKWith\(v, deriveKey\(name, pass\), h\) == nil \{\n\t\treturn nil, errors\.New\("the key did not unlock this profile"\)\n\t\}\n)(\tif err := stashFido2SlotsPre\(stateDir, slots\); err != nil \{\n\t\treturn nil, err\n\t\}\n)' '\2\1'
mut "M4 spec written to .fido2slots, not .pre" fido2_adopt.go 'stashFido2SlotsPre\(stateDir, slots\)' 'func() error { stashFido2Slots(stateDir, slots); return nil }()'

[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
