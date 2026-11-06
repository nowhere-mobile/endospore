#!/usr/bin/env bash
# test-sealdelta-mtime.sh [--mutate] -- "Changed on this phone since the last save" compares a deferred file's
# mtime in the record's own unit (NWP-20261027-03). Plain: the SealDelta walk tests. --mutate applies each mutant
# to seal_delta_walk.go in place (a pristine copy lives in one temp root, restored after every mutant and on exit)
# and runs the same tests; each must be CONVICTED by a real `--- FAIL`. A mutant that fails to apply or to
# compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(seal_delta_walk.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'SealDelta' . 2>&1); rc=$?
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
  res=$(go test -count=1 -run 'SealDelta' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
SEAL=TestSealDeltaWalkSealShapedRecordMatchesIsNotCounted
IDX=TestSealDeltaWalkSealShapedRecordThroughIdxFile
SECS=TestSealDeltaWalkImporterSecondsRecord
RULES=TestSealDeltaWalkRules
mut "Q1 rule A back to seconds against the record" seal_delta_walk.go 'if !deferredStatMatches(fi, ent) {' 'if fi.Size() != ent.size || fi.ModTime().Unix() != ent.mtime {' "$SEAL" "$IDX"
mut "Q2 both sides through deferredMTimeNanos" seal_delta_walk.go '	if ent.mtime < mtimeSecondsCeiling {
		return fi.ModTime().Unix() == ent.mtime
	}
	return fi.ModTime().UnixNano() == ent.mtime' '	return fi.ModTime().UnixNano() == deferredMTimeNanos(ent.mtime)' "$SECS" "$RULES"
mut "Q3 the size comparison dropped" seal_delta_walk.go '	if fi.Size() != ent.size {
		return false
	}
' '' "$RULES"
mut "Q4 the ceiling comparison inverted" seal_delta_walk.go 'if ent.mtime < mtimeSecondsCeiling {' 'if ent.mtime >= mtimeSecondsCeiling {' "$SEAL" "$SECS"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
