#!/usr/bin/env bash
# test-media-arrival-walked.sh [--mutate] -- the deferred-arrival fetch honours the walked roster (NWP-20261025-02): a
# deferred #media file this session created, sealed and deleted is not fetched back by a later seal, while another
# handset's new photo still is. Plain: the arrival, walked-roster, carry and sync tests. --mutate applies each mutant in
# place (pristine copies live in one temp root, restored after every mutant and on exit) and runs the arrival and sync
# tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(media_defer_sync.go main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestMediaArrival|TestMediaWalked|TestMediaCarry|TestMediaSync' . 2>&1); rc=$?
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
  res=$(go test -count=1 -run 'TestMediaArrival|TestMediaSync' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "V1 the walked skip is removed" media_defer_sync.go 'if walkedHere != nil && walkedHere(rel) {' 'if false {' TestMediaArrival_ADeferredPhotoTakenSealedAndDeletedIsNotFetchedBack TestMediaArrival_PredicateSkipsOnlyTheRelItNames
mut "V2 pushProfile passes nil" main.go 'restoredDef, src, walkedHere)' 'restoredDef, src, nil)' TestMediaArrival_ADeferredPhotoTakenSealedAndDeletedIsNotFetchedBack
mut "V3 the skip is inverted" media_defer_sync.go 'if walkedHere != nil && walkedHere(rel) {' 'if walkedHere != nil && !walkedHere(rel) {' TestMediaArrival_PredicateSkipsOnlyTheRelItNames TestMediaSync_ADeferredPhotoFromAnotherHandsetLands
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
