#!/usr/bin/env bash
# test-stranded-end-unsaved.sh [--mutate] -- runs end_unsaved_stranded_test.go (NWP-20261114-06, #19 of 2026-10-22,
# Q016: a stranded END-UNSAVED whose vault head no slot this phone holds opens ends with OK-CREDIT-LOST and no wallet
# publish); --mutate re-runs it against a COPY of the package with end_unsaved.go broken in turn (the work tree is
# never edited). Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts
# as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=$PWD
PAT='TestEndUnsaved_AStranded|TestEndUnsaved_ANoSlot|TestEndUnsaved_TheStrandedArm|TestWalletNoDKErr|TestPublishWalletBeforeDiscard|TestLogoffRefusalStranded'

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

mut "M1 stranded() always true" end_unsaved.go '(func \(r \*logoffRefusalRec\) stranded\(\) bool \{\n)' '\1\treturn true\n'
mut "M2 stranded() always false" end_unsaved.go '(func \(r \*logoffRefusalRec\) stranded\(\) bool \{\n)' '\1\treturn false\n'
# M3 is equivalent by behaviour (final is never false on that path today); the source pin convicts it.
mut "M3 the stranded arm without final" end_unsaved.go 'errors\.Is\(err, errWalletNoSlot\) && final && r\.stranded\(\)' 'errors.Is(err, errWalletNoSlot) && r.stranded()'
mut "M4 the sentinel returned as a plain error" end_unsaved.go '\treturn errWalletNoSlot\n' '\treturn errors.New("no keyslot opens this profile'"'"'s vault")\n'
mut "M5 the sentinel returned with no vault read" end_unsaved.go '\tif v != nil \{\n\t\treturn errWalletNoSlot\n' '\tif true {\n\t\treturn errWalletNoSlot\n'
mut "M6 the stranded arm answers plain OK" end_unsaved.go '(credit added this session is lost \(%s, NWP-20261114-06\)\\n",\n\t+uid, endUnsavedCreditLost\)\n\t+)reply = okAsConn\{conn, endUnsavedCreditLost\}' '\1reply = conn'

[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
