#!/usr/bin/env bash
# test-carry-empty-head.sh [--mutate] -- a #media head that is indexed but empty keeps the essential carry on at
# sign-in (NWP-20261026-03). Plain: the carry, essential-unreadable and walked-roster tests. --mutate applies each
# mutant to main.go in place (a pristine copy lives in one temp root, restored after every mutant and on exit) and
# runs the carry tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to compile
# counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestMediaCarry|TestEssentialUnreadable|TestMediaWalked' . 2>&1); rc=$?
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
  res=$(go test -count=1 -run 'TestMediaCarry' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
A=TestMediaCarry_AnEmptyIndexedHeadAtSignInStillCarries
B=TestMediaCarry_APreFlagRestoredHeadStillSkipsTheCarry
C=TestMediaCarry_TheIndexMarkerIsWrittenOnlyByAnIndexingMediaSeal
mut "E1 the skip arm ignores the marker" main.go 'case len(restoredM.Ess) == 0 && !restoredM.EssIdx:' 'case len(restoredM.Ess) == 0:' "$A"
mut "E2 the marker is dropped from the marshal literal" main.go 'EssIdx: essIdxBuilt,' 'EssIdx: essIdxBuilt && false,' "$A" "$C"
mut "E3 the marker condition is widened to true" main.go 'essIdxBuilt := mediaEssentialCarryOn(profile) && incrementalSeal()' 'essIdxBuilt := true' "$C"
mut "E4 the skip arm never fires" main.go 'case len(restoredM.Ess) == 0 && !restoredM.EssIdx:' 'case false:' "$B"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
