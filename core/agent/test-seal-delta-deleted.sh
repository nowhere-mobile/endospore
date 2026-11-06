#!/usr/bin/env bash
# test-seal-delta-deleted.sh [--mutate] -- "Changed on this phone since the last save" counts a deleted file
# (NWP-20261126-06, case (3)'s deletion half of "Your data's save copy says the wrong thing in four cases"). A
# listed file (the #media head's Deferred and Ess rels, the vault and #de scan caches of the last landed seal)
# that the walk does not meet and a stat confirms absent counts in deletedBytes/deletedFiles.
# Plain: the deletion and listed-file tests. --mutate applies each mutant to seal_delta_walk.go or seal_delta.go
# in place (pristine copies live in one temp root, restored after every mutant and on exit) and runs the same
# tests; each must be CONVICTED by a real `--- FAIL`. A mutant that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(seal_delta_walk.go seal_delta.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN='TestSealDeltaDeleted|TestSealDeltaListed'

out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <old-literal> <new-literal> [<old-literal> <new-literal>]... -- <convicting test>...
# Every old literal must occur exactly once; all edits apply before the one test run.
mut() {
  local label="$1" file="$2" res want
  local -a edits=()
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do edits+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  python3 - "$file" "${edits[@]}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, pairs = sys.argv[1], sys.argv[2:]
if not pairs or len(pairs) % 2:
    sys.exit(1)
s = open(p).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    if s.count(old) != 1:
        sys.exit(1)
    s = s.replace(old, new)
open(p, 'w').write(s)
PY
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
ESS=TestSealDeltaDeletedMediaEssListedCounts
OVL=TestSealDeltaDeletedMediaDeferredUnderOverlay
VAULT=TestSealDeltaDeletedVaultScanCacheCounts
PRESENT=TestSealDeltaDeletedPresentNotCounted
BLIND=TestSealDeltaDeletedUnderBlindDirNotCounted
ONCE=TestSealDeltaDeletedCountedOnce
UNLANDED=TestSealDeltaListedCacheOfAnUnlandedSealNotRead
OLDCACHE=TestSealDeltaListedOldCacheNotRead
MEDIAH=TestSealDeltaListedMediaHeadEssAndDeferred

mut "M1 the deletion pass skipped" seal_delta_walk.go \
  '	sealDeltaCountDeleted(&out, roots, unders, idx, listed, met, blindPre, skipPre)
' '' -- "$ESS" "$VAULT" "$OVL"
mut "M2 a key present on disk counted" seal_delta_walk.go \
  'if met[key] || counted[key] {' 'if counted[key] {' \
  '!errors.Is(err, fs.ErrNotExist) {' 'errors.Is(err, fs.ErrNotExist) && false {' -- "$PRESENT"
mut "M3 the #nocache guard dropped (a cache read after an unlanded dispatch)" seal_delta.go \
  'if started == landed {' 'if true {' -- "$UNLANDED"
mut "M3b the cache-age check dropped" seal_delta.go \
  'fi.ModTime().Unix() >= landed {' 'fi != nil {' -- "$OLDCACHE"
mut "M4 the blind suppression dropped" seal_delta_walk.go \
  'sealDeltaUnderPrefix(key, blindPre) || ' '' -- "$BLIND"
mut "M5 a key counted twice" seal_delta_walk.go \
  'if met[key] || counted[key] {' 'if met[key] {' -- "$ONCE"
mut "M6 the overlay rule for a Deferred key dropped" seal_delta_walk.go \
  'if deferred && !sealDeltaUnderOverlay(filepath.Join(root, rel), unders) {' 'if false {' -- "$OVL"
mut "M7 the listed loop never treats a key as Deferred" seal_delta_walk.go \
  'count(k, size, inIdx)' 'count(k, size, inIdx && false)' -- "$OVL"
mut "M8 the #media Ess rels not listed" seal_delta.go \
  'for rel, r := range m.Ess {' 'for rel, r := range map[string]essRegion(nil) {' -- "$MEDIAH"
mut "M9 the #media Ess rels listed only beside a Deferred one" seal_delta.go \
  'for rel, r := range m.Ess {' 'for rel, r := range m.Ess { if len(m.Deferred) == 0 { break }' -- "$MEDIAH"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
