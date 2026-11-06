#!/usr/bin/env bash
# test-carry-unread.sh [--mutate] -- runs the media-carry and unreadable-essential tests (NWP-20261025-03); --mutate
# re-runs them against media_carry.go with the "visited but unread rel keeps its span" arm of
# carryMediaEssentialRels broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a `--- FAIL`;
# one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=media_carry.go
RUN=(go test -count=1 -run 'TestMediaCarry|TestEssentialUnreadable' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$SRC" "$W/media_carry.go.orig"
trap 'cp -f "$W/media_carry.go.orig" "$SRC" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/media_carry.go.orig" "$SRC"; }
# conv <label>: run the suite against the mutated file, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: Test'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$SRC" "$2" "$3" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
ARM='\t\tcase unreadHere\(seen, rel\):\n.*?\t\t\tst\.Unread\+\+\n'
mut "U1 the unread arm removed" "$ARM" ''
mut "U2 the arm tests !seen[rel] (every unvisited rel carried)" '\{ v, ok := seen\[rel\]; return ok && !v \}' '{ return !seen[rel] }'
mut "U3 the arm moved above the tombstone arm" '(\t\tcase tomb\[rel\]:)(.*?)('"$ARM"')' '\3\1\2'
mut "U4 the arm skips the span check" '(\t\tcase unreadHere\(seen, rel\):\n.*?\t\t\tif )r\.S < 0 \|\| r\.E > oldChunks \|\| r\.E <= r\.S' '\1false && (r.S < 0 || r.E > oldChunks || r.E <= r.S)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
