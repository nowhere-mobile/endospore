#!/usr/bin/env bash
# test-media-sync-oversize.sh [--mutate] -- the mid-session deferred sync (NWP-20261026-14): one arrival larger than the
# whole per-cycle budget is skipped and counted, not allowed to end every cycle at 0 B. Plain: the TestMediaSync tests.
# --mutate applies each mutant in place (a pristine copy lives in one temp root, restored after every mutant and on
# exit) and runs the same tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to
# compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(media_defer_sync.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestMediaSync' . 2>&1); rc=$?
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
  res=$(go test -count=1 -run 'TestMediaSync' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "O1 the oversize skip removed" media_defer_sync.go 'if d.Size > budget {' 'if false {' TestMediaSync_AnOversizeArrivalDoesNotBlockTheRest
mut "O2 the remainder break becomes continue" media_defer_sync.go $'total, rel)\n\t\t\tbreak\n' $'total, rel)\n\t\t\tcontinue\n' TestMediaSync_AnArrivalThatFitsTheBudgetButNotTheRemainderStillStopsTheCycle
mut "O3 the oversize test made >=" media_defer_sync.go 'if d.Size > budget {' 'if d.Size >= budget {' TestMediaSync_AnArrivalOfExactlyTheBudgetLands
mut "O4 the count line not printed" media_defer_sync.go 'if oversize > 0 {' 'if false {' TestMediaSync_AnOversizeArrivalDoesNotBlockTheRest
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
