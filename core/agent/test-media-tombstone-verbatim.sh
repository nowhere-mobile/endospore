#!/usr/bin/env bash
# test-media-tombstone-verbatim.sh [--mutate] -- both tombstone readers keep each line as appendTombstone wrote it
# (NWP-20261129-46): mediaTombstones (media_seal.go) and loadTombstones (media_server.go). A trimmed line reads a rel
# that begins or ends in whitespace as another rel. --mutate applies each mutant in place (a pristine copy lives in
# one temp root, restored after every mutant and on exit); each must be CONVICTED by the named `--- FAIL`. A mutant
# that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(media_seal.go media_server.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
T='TestMediaTombstonesReadLinesVerbatim|TestLoadTombstonesReadLinesVerbatim|TestSealDropsATombstonedDeferredFileWhoseNameEndsInASpace'

out=$(go test -count=1 -run "$T" . 2>&1); rc=$?
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
  res=$(go test -count=1 -run "$T" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "V1 mediaTombstones trims again" media_seal.go 'if ln != "" {' 'if ln = strings.TrimSpace(ln); ln != "" {' TestMediaTombstonesReadLinesVerbatim TestSealDropsATombstonedDeferredFileWhoseNameEndsInASpace
mut "V2 loadTombstones trims again" media_server.go 'if ln != "" {' 'if ln = strings.TrimSpace(ln); ln != "" {' TestLoadTombstonesReadLinesVerbatim
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
