#!/usr/bin/env bash
# test-media-sync-names.sh [--mutate] -- the mid-session media sync (NWP-20261129-49) refuses a ".." SEGMENT, not a ".."
# inside a file name, so "DCIM/Holiday..jpg" lands without a login. Plain: the three tests of media_sync_names_test.go.
# --mutate applies each mutant in place (a pristine copy lives in one temp root, restored after every mutant and on
# exit) and runs the same tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to
# compile counts as a failure. N1 and N2 put a guard back to the substring test; N3 makes syncRelOK accept a ".." segment.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(media_span.go media_defer_sync.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
TESTS='^(TestSyncRelOK|TestMediaSync_AnEssentialNameHoldingTwoDotsLands|TestMediaSync_ADeferredNameHoldingTwoDotsLands)$'

out=$(go test -count=1 -run "$TESTS" . 2>&1); rc=$?
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
  res=$(go test -count=1 -run "$TESTS" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
SUBSTR='if rel == "" || strings.HasPrefix(rel, "/") || strings.Contains(rel, "..") {'
mut "N1 materializeCarried's guard back to the substring test" media_span.go 'if !syncRelOK(rel) {' "$SUBSTR" TestMediaSync_AnEssentialNameHoldingTwoDotsLands
mut "N2 newlyArrivedDeferred's guard back to the substring test" media_defer_sync.go 'if !syncRelOK(rel) {' "$SUBSTR" TestMediaSync_ADeferredNameHoldingTwoDotsLands
mut "N3 syncRelOK accepts a .. segment" media_span.go 'if seg == ".." {' 'if false && seg == ".." {' TestSyncRelOK
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
