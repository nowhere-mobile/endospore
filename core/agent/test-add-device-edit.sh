#!/usr/bin/env bash
# test-add-device-edit.sh [--mutate] -- NWP-20261111-10: ADD-DEVICE (hardenVaultTo) edits the vault it reads INSIDE
# its bracket (capReadVaultForEdit), so a publish made between the caller's read and the bracket is kept and one made
# after the in-bracket read is refused at the flush. NWP-20261114-03: the scope-slot bracket (addScopeSlotsAfterEnrol)
# is no-login too, as hardenVaultTo's is, so a departed profile's wallet is never folded or spent; M5 puts capWrite back.
# --mutate applies each mutant to a pristine copy of add_device.go (restored on exit) and requires a real `--- FAIL`:
# a mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp add_device.go "$W/ad.orig" || exit 2
trap 'cp "$W/ad.orig" add_device.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestAddDevice|TestTwoHandsets|TestCapModeEnrollSE|TestEnrollSE|TestEveryGoroutineGoesThroughGoSafe|TestNoLogPrintsAProfileNameOutsideQuotes"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new>: replace the first <old> in a pristine copy of add_device.go, require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" res
  cp "$W/ad.orig" add_device.go
  if ! OLD="$old" NEW="$new" python3 -c "
import os
f = 'add_device.go'
s = open(f).read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "TestAddDeviceEdit|TestAddDeviceScopeSlots_" . 2>&1)
  if grep -q -E '\[build failed\]|build failed|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  elif grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "M1 the edit applied to the caller's v" 'cur.Slots = append(cur.Slots,' $'cur = v\n\t\tcur.Slots = append(cur.Slots,'
mutate "M2 the in-bracket read arms nothing" 'cur, err := capReadVaultForEdit(base, "add-device", name, pass, dk, v.Sig != "")' \
  $'_, cur, _ := readVaultHead(base, name, pass)\n\t\tvar err error'
mutate "M3 Version taken from v" 'cur.Version++' 'cur.Version = v.Version + 1'
mutate "M4 the in-bracket idempotence check removed" 'if unwrapDK(cur, "se", kek) != nil {' 'if false && unwrapDK(cur, "se", kek) != nil {'
mutate "M5 the scope-slot bracket counts the wallet as ours" \
  $'vd := capWriteNoLogin(name, pass, dk, func() {\n\t\tif err = addScopeSESlots(' \
  $'vd := capWrite(name, pass, dk, func() {\n\t\tif err = addScopeSESlots('
cp "$W/ad.orig" add_device.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
