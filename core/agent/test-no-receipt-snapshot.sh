#!/usr/bin/env bash
# test-no-receipt-snapshot.sh [--mutate] -- NWP-20261203-16: each no-receipt SEAL REFUSED line in pushProfile is followed
# by `push: #<scope> no-receipt snapshot: dir= files= have= park=`, codes and counts only (receiptSnapshot,
# restore_receipt.go), so the next device proof names why the receipt was missing. Runs no_receipt_snapshot_test.go;
# --mutate applies each mutant to main.go or restore_receipt.go in place (both restored on exit) and requires a real
# `--- FAIL` of the named test: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" main.go; [ -f "$W/rr.go.orig" ] && cp -f "$W/rr.go.orig" restore_receipt.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestNoReceiptSnapshot'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

cp main.go "$W/main.go.orig" || exit 2
cp restore_receipt.go "$W/rr.go.orig" || exit 2
FAILS=0
restore() {
  cp -f "$W/main.go.orig" main.go
  cp -f "$W/rr.go.orig" restore_receipt.go
}
# mutate <label> <test> <file> <old> <new>: replace the one occurrence of old in a pristine file, require a real
# --- FAIL of <test>
mutate() {
  local lbl="$1" tst="$2" file="$3" old="$4" new="$5" o r
  restore
  if ! python3 - "$file" "$old" "$new" <<'PY'
import sys
f, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f).read()
if s.count(old) != 1:
    raise SystemExit('mutant did not apply: %d matches' % s.count(old))
open(f, 'w').write(s.replace(old, new, 1))
PY
  then
    echo "  BROKEN    $lbl -- the mutant did not apply"; FAILS=$((FAILS+1)); restore; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1); r=$?
  if score_mutant "$lbl" "$r" "$o"; then
    if [[ "$o" != *"--- FAIL: $tst "* ]]; then
      echo "    but $tst did not fail"; FAILS=$((FAILS+1))
    fi
  else
    FAILS=$((FAILS+1))
  fi
  restore
}
echo "== mutations =="
mutate "S1: the snapshot print removed from the early site (RefusalPrints)" TestNoReceiptSnapshot_RefusalPrints main.go \
  $'logProfile(profile), oldN)\n\t\t\t\tlogNoReceiptSnapshot(profile, pass)\n' $'logProfile(profile), oldN)\n'
mutate "S2: have skips keys (Shapes b)" TestNoReceiptSnapshot_Shapes restore_receipt.go \
  $'scopeIndexSuffixes...) {\n\t\tif !haveRestoreReceipt' \
  $'scopeIndexSuffixes...) {\n\t\tif suf == "#keys" {\n\t\t\tcontinue\n\t\t}\n\t\tif !haveRestoreReceipt'
mutate "S3: the park check reads \$STATE instead of .in-park (Shapes a and c)" TestNoReceiptSnapshot_Shapes restore_receipt.go \
  'p := filepath.Join(st, inParkDir)' 'p := st'
mutate "S4: files counts roster, walked and .tmp entries (Shapes b)" TestNoReceiptSnapshot_Shapes restore_receipt.go \
  'if isReceiptName(e.Name()) {' 'if e.Name() != "" {'
mutate "S5: the line prints logProfile(profile) (RefusalPrints)" TestNoReceiptSnapshot_RefusalPrints restore_receipt.go \
  'label, receiptSnapshot(profile, pass))' 'logProfile(profile), receiptSnapshot(profile, pass))'
[ "$FAILS" = 0 ] || { echo "== $FAILS mutant(s) not convicted"; exit 1; }
echo "== 5 mutants convicted"
