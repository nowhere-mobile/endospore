#!/usr/bin/env bash
# test-receipt-atomic.sh [--mutate] -- NWP-20261112-20: restore receipts and login rosters are published by temp +
# rename (publishReceiptFile in restore_receipt.go), so a reader never sees a torn or empty receipt and a failed write
# leaves the previous receipt (and a roster's walked roster) exactly as they were. --mutate applies each mutant to a
# pristine copy of restore_receipt.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply,
# or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp restore_receipt.go "$W/rr.orig" || exit 2
trap 'cp "$W/rr.orig" restore_receipt.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestReceiptAtomic|TestRestoreReceipt|TestReceiptGate|TestMediaWalked|TestNoLogPrintsAProfileNameOutsideQuotes|TestEveryGoroutineGoesThroughGoSafe"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new>: replace the first <old> in a pristine copy of restore_receipt.go, require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" res rc
  cp "$W/rr.orig" restore_receipt.go
  if ! OLD="$old" NEW="$new" python3 -c "
import os
f = 'restore_receipt.go'
s = open(f).read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "TestReceiptAtomic" . 2>&1); rc=$?
  score_mutant "$lbl" "$rc" "$res" || FAILS=$((FAILS+1))
}
mutate "M1 writeRestoreReceipt rewrites in place" \
  'if publishReceiptFile(f, []byte(head+"\n")) != nil {' \
  'if os.WriteFile(f, []byte(head+"\n"), 0o600) != nil {'
mutate "M2 writeLoginRoster rewrites in place" \
  'if publishReceiptFile(f, []byte(head)) != nil {' \
  'if os.WriteFile(f, []byte(head), 0o600) != nil {'
mutate "M3 a failed rename leaves the temp" \
  $'\tif err := os.Rename(tmp, f); err != nil {\n\t\tos.Remove(tmp)\n' \
  $'\tif err := os.Rename(tmp, f); err != nil {\n'
mutate "M4 writeLoginRoster removes the walked roster regardless of the write" \
  $'\t\tfmt.Fprintln(os.Stderr, "restore receipt not updated -- the previous one stands (#72)")\n\t\treturn\n' \
  $'\t\tfmt.Fprintln(os.Stderr, "restore receipt not updated -- the previous one stands (#72)")\n'
cp "$W/rr.orig" restore_receipt.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
