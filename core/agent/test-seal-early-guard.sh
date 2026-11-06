#!/usr/bin/env bash
# test-seal-early-guard.sh [--mutate] -- the walk-independent seal guards (no-receipt, and stale-base for a profile the
# media carry cannot excuse) refuse BEFORE anything is uploaded or leased (NWP-20261101-09, #120). Plain: the SealEarlyGuard
# tests plus the PushGuard / TwoWriter tests that pin the guards' reasons. --mutate applies each mutant to main.go in
# place (a pristine copy lives in one temp root, restored after every mutant and on exit) and runs the SealEarlyGuard
# tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'SealEarlyGuard|PushGuard|TwoWriter' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <mutator> <convicting test>... -- <mutator> is a python3 program run with the file's text in `s`,
# leaving the mutated text in `s`; it exits 1 when its anchor is not found exactly once.
mut() {
  local label="$1" file="$2" prog="$3" res want
  shift 3
  python3 -c "
import sys
p = sys.argv[1]
s = open(p).read()
$prog
open(p, 'w').write(s)
" "$file" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
  res=$(go test -count=1 -run 'SealEarlyGuard' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
# G1: the early no-receipt block moved back after the walk (cut here, pasted before the secondary net).
G1='
a = s.find("\t\tif oldN > 0 && restoreReceiptDir() != \"\" && !haveRestoreReceipt(rcptRef) {\n")
e = s.find("\t\t\treturn\n\t\t}\n", a) + len("\t\t\treturn\n\t\t}\n")
mark = "\t\t// Secondary net (defense-in-depth)"
if a < 0 or s.count(mark) != 1 or s.count("!haveRestoreReceipt(rcptRef)") != 1:
    sys.exit(1)
blk = s[a:e]
s = s[:a] + s[e:]
s = s.replace(mark, blk + mark)
'
# G2: the early stale-base arm also runs for a profile the media carry can excuse.
G2='
old = "!mediaEssentialCarryOn(profile) && oldN > 0"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "oldN > 0")
'
# G3: the early block ignores NOWHERE_SEAL_FORCE.
G3='
old = "\tif os.Getenv(\"NOWHERE_SEAL_FORCE\") != \"1\" {\n\t\toldN := len(oldM.Chunks)\n\t\tif !mediaEssentialCarryOn"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "\tif true {\n\t\toldN := len(oldM.Chunks)\n\t\tif !mediaEssentialCarryOn")
'
mut "G1 no-receipt runs after the walk again" main.go "$G1" TestSealEarlyGuard_NoReceiptRefusesBeforeAnythingIsUploaded
mut "G2 stale-base refuses a carry-excusable profile early" main.go "$G2" TestSealEarlyGuard_TheCarryExcusedStaleBaseStillReachesTheWalk
mut "G3 the early block ignores the force override" main.go "$G3" TestSealEarlyGuard_ForceBypassesBoth
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
