#!/usr/bin/env bash
# test-carry-no-writeback.sh [--mutate] -- NWP-20261026-01: the post-seal sync writes back only the carried rels the
# walk NEVER visited. A rel the walk visited but could not read (a photo deleted between the walk's stat and its
# open) keeps its span in the head for one cycle and is not fetched onto the phone. Plain: the unreadable, carry and
# sync tests. --mutate applies each mutant in place (pristine copies live in one temp root, restored after every
# mutant and on exit); each must be CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to compile
# counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(media_carry.go main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestEssentialUnreadable|TestCarriedToLand|TestMediaCarry|TestMediaSync' . 2>&1); rc=$?
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
  res=$(go test -count=1 -run 'TestEssentialUnreadable|TestCarriedToLand|TestMediaSync' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "V1 the call site lands every carried rel" main.go 'materializeCarried(base, dk, oldM, carriedToLand(landRels, seen), src, budget)' 'materializeCarried(base, dk, oldM, landRels, src, budget)' TestEssentialUnreadable_AFileDeletedMidSealIsNotWrittenBack
mut "V2 carriedToLand keeps only visited rels" media_carry.go 'if _, visited := seen[rel]; !visited {' 'if _, visited := seen[rel]; visited {' TestMediaSync_AnotherHandsetsPhotoLandsWithoutALogin TestCarriedToLand
mut "V3 carriedToLand tests the value, not the key" media_carry.go 'if _, visited := seen[rel]; !visited {' 'if !seen[rel] {' TestEssentialUnreadable_AFileDeletedMidSealIsNotWrittenBack TestCarriedToLand
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
