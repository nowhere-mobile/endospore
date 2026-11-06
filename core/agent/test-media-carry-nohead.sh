#!/usr/bin/env bash
# test-media-carry-nohead.sh [--mutate] -- a sign-in that found no #media head records an empty login roster, so the
# session's seals run the essential carry (NWP-20261026-08). Plain: the no-head, carry, index and walked-roster tests.
# --mutate applies each mutant in place (pristine copies live in one temp root, restored after every mutant and on exit)
# and runs the no-head tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to
# compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go restore_receipt.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestMediaCarryNoHead|TestMediaCarryIndex|TestMediaCarry|TestMediaWalked' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want
  shift 4
  python3 - "$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -run 'TestMediaCarryNoHead' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
P=TestMediaCarryNoHead_
A=${P}ASecondHandsetsNewFileSurvivesTheFirstOnesSeals
C=${P}AFailedProbeWritesNoSentinel
D=${P}OtherScopesRecordNothing
E=${P}TheRestoreVerbNotesItsEmptyArm
mut "N1 the sentinel is never written" restore_receipt.go $'\twriteLoginRosterNone(profileRefV2(profile, pass))\n' $'\t_ = profileRefV2(profile, pass)\n' "$A"
mut "N2 the strict probe is skipped" restore_receipt.go 'if !isSharedMediaScope(profile) || proveNoMediaHead(base, profile, pass) != nil {' 'if !isSharedMediaScope(profile) {' "$C"
mut "N3 the switch reads the sentinel as no roster" main.go 'case rh == "":' 'case rh == "" || rh == loginRosterNone:' "$A"
mut "N4 the scope check is removed" restore_receipt.go 'if !isSharedMediaScope(profile) || proveNoMediaHead(base, profile, pass) != nil {' 'if proveNoMediaHead(base, profile, pass) != nil {' "$D"
mut "N5 the restore arm never notes" main.go $'\t\t\tnoteNoMediaHeadAtLogin(base, profile, pass)\n' '' "$E"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
