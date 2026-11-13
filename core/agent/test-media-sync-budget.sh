#!/usr/bin/env bash
# test-media-sync-budget.sh [--mutate] -- NWP-20261129-25: the post-seal media sync is bounded in the essential tier and
# skipped at the sign-out's own seal. Plain: the TestMediaSync tests and TestSignOutSealKinds. --mutate applies each
# mutant in place (pristine copies live in one temp root, restored after every mutant and on exit); each must be
# CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go media_span.go media_defer_sync.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
T='TestMediaSync|TestSignOutSealKinds'

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
mut "S1 the sign-out gate removed" main.go 'if signOutSeal() {' 'if false {' TestMediaSync_ASignOutSealFetchesNothing
mut "S2 the oversize skip removed" media_span.go 'if r.Size > budget {' 'if false {' TestMediaSync_AnOversizeEssentialFileWaitsAndTheRestLand
mut "S3 the remainder check removed" media_span.go 'if total+r.Size > budget {' 'if false {' TestMediaSync_AnEssentialFileThatFitsTheBudgetButNotTheRemainderEndsThePass
mut "S4 the oversize skip ends the pass" media_span.go $'oversize++\n\t\t\tcontinue' $'oversize++\n\t\t\tbreak' TestMediaSync_AnOversizeEssentialFileWaitsAndTheRestLand
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
