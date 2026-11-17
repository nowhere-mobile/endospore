#!/usr/bin/env bash
# test-store-xfer.sh [--mutate] -- NWP-20261203-10: a managed-store chunk GET and PUT go through storeXfer
# (store_xfer.go), bounded by a deadline scaled to the bytes in flight and rechecked when it fires, and a GET also
# by a stall timer, instead of storeHTTP's 60 s whole-request Timeout. Runs the focused Go tests; --mutate applies
# each mutant to a pristine copy of main.go or store_xfer.go (both restored on exit) and requires a real `--- FAIL`:
# a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp store_xfer.go "$W/store_xfer.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/store_xfer.go.orig" store_xfer.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestStoreXfer|TestCapGetFitsTheStallBudget|TestSealGatewayLegFitsTheStallBudget'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <test regex> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
# from the named test (the assertion that convicts it).
mutate() {
  local lbl="$1" f="$2" run="$3" body="$4" o
  cp "$W/$f.orig" "$f"
  if ! python3 -c "
import sys
f = sys.argv[1]
s = open(f).read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open(f, 'w').write(t)" "$f"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); cp "$W/$f.orig" "$f"; return
  fi
  o=$(go test -count=1 -run "$run" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  cp "$W/$f.orig" "$f"
}
echo "== mutations =="
mutate "m1: capPutErrGuarded sends through storeHTTP.Do again" main.go 'TestStoreXferPutSlowAnswerLands$' "
t = s.replace('resp, err := storeXfer(req, int64(len(data)))', 'resp, err := storeHTTP.Do(req)', 1)"
mutate "m2: capGetMaxOpt reads through storeHTTP.Get again" main.go 'TestStoreXferGetSlowStreamLands$' "
t = s.replace('resp, gerr := storeXfer(req, est)', 'resp, gerr := storeHTTP.Get(u)\n\t\t_, _ = req, est', 1)"
mutate "m3: a body Read no longer restarts the stall timer" store_xfer.go 'TestStoreXferGetSlowStreamLands$' "
t = s.replace('\t\tb.st.Reset(storeXferStall)\n', '\t\t_ = b.st\n', 1)"
mutate "m4: the deadline ignores the bytes in flight (DeadlineScales)" store_xfer.go 'TestStoreXferDeadlineScales$' "
t = s.replace('d := storeXferFloor + time.Duration(inflight)*time.Second/time.Duration(storeXferMinRate)', 'd := storeXferFloor + 0*time.Duration(inflight)', 1)"
mutate "m4: the deadline ignores the bytes in flight (PutSlowAnswerLands)" store_xfer.go 'TestStoreXferPutSlowAnswerLands$' "
t = s.replace('d := storeXferFloor + time.Duration(inflight)*time.Second/time.Duration(storeXferMinRate)', 'd := storeXferFloor + 0*time.Duration(inflight)', 1)"
mutate "m5: the ceiling is removed" store_xfer.go 'TestStoreXferDeadlineCeiling$' "
t = s.replace('\tif d > storeXferCeil {\n\t\treturn storeXferCeil\n\t}\n', '', 1)"
mutate "m6: a Do error does not release the share" store_xfer.go 'TestStoreXferReleasesInflight$' "
t = s.replace('\tif err != nil {\n\t\trelease()\n\t\treturn nil, storeXferErr(ctx, err)', '\tif err != nil {\n\t\treturn nil, storeXferErr(ctx, err)', 1)"
mutate "m7: the ContentLength is not applied to the share" store_xfer.go 'TestStoreXferContentLengthRearms$' "
t = s.replace('\t\told := share.Swap(resp.ContentLength)\n\t\tatomic.AddInt64(&storeXferInflight, resp.ContentLength-old)\n', '', 1)"
mutate "m8: the stall timer starts after Do" store_xfer.go 'TestStoreXferGetHungHeaders$' "
t = s.replace('st = time.NewTimer(storeXferStall)', 'st = time.NewTimer(time.Hour)', 1)
if t != s: t = t.replace('\tresp, err := c.Do(req)\n', '\tresp, err := c.Do(req)\n\tif st != nil {\n\t\tst.Reset(storeXferStall)\n\t}\n', 1)"
mutate "m9: the deadline cancels when it fires, with no recheck" store_xfer.go 'TestStoreXferDeadlineRechecksInflight$' "
t = s.replace('\t\t\t\tif left := time.Until(end); left > 0 {\n\t\t\t\t\tdl.Reset(left)\n\t\t\t\t\tcontinue\n\t\t\t\t}\n', '\t\t\t\t_ = end\n', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "10 mutant runs (9 mutants) convicted"
