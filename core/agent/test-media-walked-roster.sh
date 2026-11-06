#!/usr/bin/env bash
# test-media-walked-roster.sh [--mutate] -- the #media walked roster (NWP-20261025-01): a file this session created,
# sealed and deleted is not carried back. Plain: the walked-roster tests plus the carry / sync / two-writer suites they
# sit beside. --mutate applies each mutant in place (pristine copies live in one temp root, restored after every mutant
# and on exit) and runs the walked-roster and carry tests; each must be CONVICTED by the named `--- FAIL`. A mutant that
# fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(media_carry.go restore_receipt.go main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestMediaWalked|TestMediaCarry|TestMediaSync|TestSharedMedia|TestEssentialUnreadable|TestTwoWriters' . 2>&1); rc=$?
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
  res=$(go test -count=1 -run 'TestMediaWalked|TestMediaCarry' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "R1 roster arm ignores the walked predicate" media_carry.go ' || (walkedHere != nil && walkedHere(rel))' '' TestMediaWalked_ASmallFileCreatedSealedAndDeletedIsNotCarriedBack
mut "R2 the commit records carried rels too" main.go $'\t\t\trecordWalkedRoster(rcptRef, dk, walked)\n' $'\t\t\tfor rel := range carriedEss {\n\t\t\t\twalked = append(walked, rel)\n\t\t\t}\n\t\t\trecordWalkedRoster(rcptRef, dk, walked)\n' TestMediaWalked_AFileOnlyACarryBroughtIsNotInTheWalkedRoster
mut "R3 the record writes the rel, not its digest" restore_receipt.go 'set[walkedDigest(dk, rel)] = true' 'set[rel] = true' TestMediaWalked_TheRosterHoldsNoFileName
mut "R4 writeLoginRoster leaves the walked file" restore_receipt.go '_ = os.Remove(w)' '_ = w' TestMediaWalked_ANewLoginRosterResetsIt
mut "R5 the record runs before the commit guards" main.go $'\t\t\t\tmediaCarryRan = true\n' $'\t\t\t\tmediaCarryRan = true\n\t\t\t\tfor rel, ok := range seen {\n\t\t\t\t\tif ok {\n\t\t\t\t\t\trecordWalkedRoster(rcptRef, dk, []string{rel})\n\t\t\t\t\t}\n\t\t\t\t}\n' TestMediaWalked_ARefusalAfterTheCarryRecordsNothing
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
