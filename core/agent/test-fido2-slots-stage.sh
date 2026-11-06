#!/usr/bin/env bash
# test-fido2-slots-stage.sh [--mutate] -- runs fido2_slots_stage_test.go (NWP-20261112-15: a keyed sign-in stages its
# slot spec atomically or does not commit); --mutate re-runs it against a COPY of the package with stashFido2SlotsPre
# or one of its callers broken in turn (the work tree is never edited). Each mutant must be CONVICTED by a
# `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=$PWD
PAT='SlotStage'

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

mut "M1 the spec is written in place" fido2.go '(func stashFido2SlotsPre\(.*?)tmp := p \+ "\.tmp"' '\1tmp := p'
mut "M2 a failed write returns nil" fido2.go '(func stashFido2SlotsPre\(.*?)return fmt\.Errorf\("slot spec not staged: %w", err\)' '\1return nil'
mut "M3 the NFC fresh login ignores the error" fido2_nfc_verb.go '\t\tif err := stashFido2SlotsPre\(dest, slots\); err != nil \{\n.*?\n\t\t\}\n' '\t\tstashFido2SlotsPre(dest, slots)\n'
mut "M4 the NFC stash moved after the assert" fido2_nfc_verb.go '(\t\tif err := stashFido2SlotsPre\(dest, slots\); err != nil \{\n.*?\n\t\t\}\n)(\t\}\n\tconn\.SetDeadline.*?\n\t\}\n)(\t// NWP-20260924-01)' '\2\1\3'
mut "M5 the adopt ignores the error" fido2_adopt.go 'if err := stashFido2SlotsPre\(stateDir, slots\); err != nil \{\n\t\treturn nil, err\n\t\}' 'stashFido2SlotsPre(stateDir, slots)'

[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
