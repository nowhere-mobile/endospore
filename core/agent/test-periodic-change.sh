#!/usr/bin/env bash
# test-periodic-change.sh [--mutate] -- NWP-20261202-10: the periodic save's change test (periodic_change.go and its gate
# in syncLoop). A cycle saves only with no landed save, at the 60-minute floor, on a shrink or wallet mark, or when the
# change walk reports a change; every doubt saves. --mutate re-runs the named tests against periodic_change.go / main.go
# with each guard broken in turn, restoring both on exit. Each mutant must be CONVICTED by a `--- FAIL` of every test
# its line names; one that fails to apply, or fails to compile, counts as a failure. Leaves nothing behind.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig"
cp periodic_change.go "$W/periodic_change.go.orig"
trap 'cp -f "$W/main.go.orig" main.go 2>/dev/null; cp -f "$W/periodic_change.go.orig" periodic_change.go 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/tmp" "$W/gotmp"
export TMPDIR="$W/tmp" GOTMPDIR="$W/gotmp"
RUN=(go test -count=1 -run 'TestPeriodicChange' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { cp "$W/main.go.orig" main.go; cp "$W/periodic_change.go.orig" periodic_change.go; }
# conv <label> <test>...: run the named tests against the mutated file; every one must fail. Then restore both files.
conv() {
  local label="$1" res t missed=""
  shift
  res=$(go test -count=1 -run "^($(IFS='|'; echo "$*"))\$" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1)); restore; return; fi
  for t in "$@"; do
    [[ "$res" == *"--- FAIL: $t "* ]] || missed="$missed $t"
  done
  if [ -z "$missed" ]; then echo "  convicted $label (by $*)"
  else echo "  SURVIVED  $label -- not failed:$missed"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <file> <python-regex pattern> <replacement> <test>...: exactly one match, or INERT.
mut() {
  local label="$1" file="$2" pat="$3" rep="$4"
  shift 4
  python3 - "$file" "$pat" "$rep" <<'PY' || { inert "$label"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$label" "$@"
}
D2=TestPeriodicChangeD2Floor D3=TestPeriodicChangeD3Dirty D4=TestPeriodicChangeD4ProbeErr D5=TestPeriodicChangeD5OldAgent
D6=TestPeriodicChangeD6Changed L1=TestPeriodicChangeL1NoChangeSkips L3=TestPeriodicChangeL3ShrinkMarks
L4=TestPeriodicChangeL4WalletMarks L5=TestPeriodicChangeL5MarkDuringTheSealSurvives S1=TestPeriodicChangeS1GatePlacement
PC=periodic_change.go
mut "M1 floor removed" $PC \
  'if now\.Unix\(\)-lastLanded >= int64\(periodicChangeFloor/time\.Second\) \{' 'if false {' "$D2"
mut "M2 old-agent read as nochange" $PC 'return true, "old-agent"' 'return false, "nochange"' "$D5"
mut "M3 probe error read as nochange" $PC \
  'if err != nil \{\n\t\treturn true, "probe-err"\n\t\}\n(\tr, ok := parsePeriodicChange\(reply\)\n\tif !ok \{\n)\t\treturn true, "probe-err"' \
  'if err != nil {\n\t\treturn false, "nochange"\n\t}\n\1\t\treturn false, "nochange"' "$D4"
mut "M4 deletedUnknown ignored" $PC 'if len\(r\.DeletedUnknown\) > 0 \{' 'if false {' "$D6"
mut "M5 dirty ignored" $PC 'if dirty \{\n\t\treturn "dirty"' 'if false {\n\t\treturn "dirty"' "$D3" "$L3"
mut "M6 wallet stamp ignored" $PC '(func periodicNoteWallet\(dest string\) \{\n)' '\1\treturn\n' "$L4"
mut "M7 skip arm without maybePayRent" main.go \
  '\t\t\tmaybePayRent\(dest, name, pass, wgen\)\n(\t\t\tcontinue\n)' '\1' "$S1" "$L1"
mut "M8 skip arm without retrySessionWallet" main.go \
  '(periodicNoChangeSkips\.Add\(1\)\n)\t\t\tretrySessionWallet\(dest, name, pass, seFromSession\(dest\), wgen, walletSignInWait\)\n' \
  '\1' "$S1" "$L1"
mut "M9 gate after the announce" main.go \
  '(\t\tperiodicNoteWallet\(dest\)\n.*?\t\t\tcontinue\n\t\t\}\n)(.*?delete-or-rotate-in-flight\\n"\)\n\t\t\tcontinue\n\t\t\}\n)' \
  '\2\1' "$S1"
mut "M10 mark cleared at the verdict instead of the announce" main.go \
  '\t\tperiodicDirty\.Store\(false\)[^\n]*\n(.*?periodicSealVerdict\(dest, out\)[^\n]*\n)' \
  '\1\t\tperiodicDirty.Store(false)\n' "$L5"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
