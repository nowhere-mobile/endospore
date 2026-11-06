#!/usr/bin/env bash
# test-device-label.sh [--mutate] -- NWP-20261114-24: this phone's device label (device_label.go) sits beside its own
# chip slot, sealed under the profile's DK, because the vault head is plaintext JSON. tieSlots and hardenVaultTo
# (ADD-DEVICE) set it on THIS phone's `se` slot only; SET-DEVICE-LABEL, the gate-only verb, names the phone.
# Backlog row "The unit label embeds the unit id, so the device-naming rule decided in `NWP-20260912-01` cannot ship".
# --mutate applies each mutant to a pristine copy of its file (every copy restored on exit) and requires a real
# `--- FAIL`: a mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES="device_label.go se_tie.go add_device.go owner_key.go"
for f in $FILES; do cp "$f" "$W/$f.orig" || exit 2; done
trap 'for f in $FILES; do cp "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestDeviceLabel|TestValidDeviceLabel|TestSlotLabel|TestTieSlotsSealsThisPhonesLabel|TestTieThenUntieRoundTrip|TestTwoHandsetsBothWorkAfterAddDevice|TestSetDeviceLabel|TestGateOnly|TestNoLogPrintsAProfileNameOutsideQuotes"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <old> <new>: replace the one <old> in a pristine copy of <file>, require a real --- FAIL
mutate() {
  local lbl="$1" file="$2" old="$3" new="$4" res rc
  cp "$W/$file.orig" "$file"
  if ! F="$file" OLD="$old" NEW="$new" python3 -c "
import os
f = os.environ['F']
s = open(f).read()
n = s.count(os.environ['OLD'])
if n != 1: raise SystemExit('mutant anchor matched %d times, want 1' % n)
open(f, 'w').write(s.replace(os.environ['OLD'], os.environ['NEW'], 1))"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); cp "$W/$file.orig" "$file"; return
  fi
  res=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
  score_mutant "$lbl" "$rc" "$res" || FAILS=$((FAILS+1))
  cp "$W/$file.orig" "$file"
}
mutate "M1 the slot label stored in the clear" device_label.go \
  'return base64.StdEncoding.EncodeToString(seal(dk, []byte(label)))' $'_ = base64.StdEncoding\n\treturn label'
mutate "M2 tieSlots omits the label" se_tie.go \
  ', LabelSealed: sealSlotLabel(dk, deviceLabel())}}' '}}'
mutate "M3 the label on every se slot" se_tie.go \
  $'\t\t\tkept = append(kept, s)\n\t\t}\n\t}\n\tv.Slots = kept\n\tv.Hardened = true' \
  $'\t\t\tkept = append(kept, s)\n\t\t\tif s.Kind == "se" {\n\t\t\t\tkept[len(kept)-1].LabelSealed = sealSlotLabel(dk, deviceLabel())\n\t\t\t}\n\t\t}\n\t}\n\tv.Slots = kept\n\tv.Hardened = true'
mutate "M4 deviceLabel ignores the file" device_label.go \
  'if t := strings.TrimSpace(string(b)); validDeviceLabel(t) {' 'if t := strings.TrimSpace(string(b)); false && validDeviceLabel(t) {'
mutate "M5 validDeviceLabel accepts a newline" device_label.go \
  'if !unicode.IsPrint(r) {' "if !unicode.IsPrint(r) && r != '\\n' {"
mutate "M6 SET-DEVICE-LABEL not gate-only" owner_key.go \
  '"BOOT-SWEEP", "SET-DEVICE-LABEL", "BT-WIPE",' '"BOOT-SWEEP", "BT-WIPE",'
mutate "M7 the add-device slot omits the label" add_device.go \
  'LabelSealed: sealSlotLabel(dk, label)})' '}); _ = label'
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
