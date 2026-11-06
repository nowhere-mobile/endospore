#!/usr/bin/env bash
# test-tel-pending-count.sh [--mutate] -- runs the TestTelPendingCount* cases (NWP-20261026-28): a mailbox row and its
# .pend copy are one record. --mutate re-runs them against telephony_count.go with the pairing skipped, the row hashed
# with the wrong uid, a short row skipped and a partial row counted. Each mutant must be CONVICTED by a `--- FAIL`;
# one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=telephony_count.go
RUN=(go test -count=1 -run '^TestTelPendingCount' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$SRC" "$W/orig.go"
trap 'cp -f "$W/orig.go" "$SRC" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/orig.go" "$SRC"; }
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: TestTelPendingCount'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
mut() { # mut <label> <python-regex> <replacement>: exactly one match, or INERT.
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
mut "M1 the pairing skipped: every row counted" 'len\(f\) >= 2 && paired\(f\[0\]\+" "\+f\[1\]\)' 'len(f) >= 2 && false'
mut "M2 the row hashed with the SIM tag, not the mailbox uid" 'rowKeyHash\(m\[1\], key\)' 'rowKeyHash(m[2], key)'
mut "M3 a row with fewer than two fields skipped" 'len\(f\) >= 2 && paired' 'len(f) < 2 || paired'
mut "M4 a partial trailing row counted" '\t\t\tbreak // a trailing segment with no newline is not a row' '\t\t\trows++\n\t\t\tbreak'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
