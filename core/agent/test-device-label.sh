#!/usr/bin/env bash
# test-device-label.sh [--mutate] -- NWP-20261114-24: this phone's device label (device_label.go) sits beside its own
# chip slot, sealed under the profile's DK, because the vault head is plaintext JSON. tieSlots and hardenVaultTo
# (ADD-DEVICE) set it on THIS phone's `se` slot only; SET-DEVICE-LABEL, the gate-only verb, names the phone.
# Backlog row "The unit label embeds the unit id, so the device-naming rule decided in `NWP-20260912-01` cannot ship".
# NWP-20261206-01: the no-cleartext-label check (clearLabelFindings, device_label_test.go) decodes the vault and checks
# each slot field, so base64 noise cannot fail it; M1 and M8-M10 must be convicted by that check's own line, M11 and M12
# by TestClearLabelFindingsIgnoresBase64Noise. device_label_test.go is in FILES so its mutants are restored on exit.
# --mutate applies each mutant to a pristine copy of its file (every copy restored on exit) and requires a real
# `--- FAIL`: a mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES="device_label.go se_tie.go add_device.go owner_key.go device_label_test.go"
for f in $FILES; do cp "$f" "$W/$f.orig" || exit 2; done
trap 'for f in $FILES; do cp "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestDeviceLabel|TestValidDeviceLabel|TestSlotLabel|TestTieSlotsSealsThisPhonesLabel|TestTieThenUntieRoundTrip|TestTwoHandsetsBothWorkAfterAddDevice|TestSetDeviceLabel|TestGateOnly|TestNoLogPrintsAProfileNameOutsideQuotes|TestClearLabelFindings|TestAddDevice"
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
# mutate_msg <label> <file> <old> <new>: mutate, and the run must also print the clear-label check's own line. A bare
# "in the clear" is not enough: TestSlotLabelRoundTrip prints it too, so a conviction by that test would count.
mutate_msg() {
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
  if ! score_mutant "$lbl" "$rc" "$res"; then
    FAILS=$((FAILS+1))
  elif [[ "$res" != *'the encoded vault holds the label in the clear'* ]]; then
    echo "  WRONG     $lbl -- convicted, but not by the clear-label check"; tail -n 15 <<<"$res"; FAILS=$((FAILS+1))
  fi
  cp "$W/$file.orig" "$file"
}
mutate_msg "M1 the slot label stored in the clear" device_label.go \
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
mutate_msg "M8 the label in the clear on this phone's se slot" se_tie.go \
  'LabelSealed: sealSlotLabel(dk, deviceLabel())}}' 'LabelSealed: sealSlotLabel(dk, deviceLabel()), Label: deviceLabel()}}'
mutate_msg "M9 the label in the clear in a non-se slot field" se_tie.go \
  $'\t\t\tkept = append(kept, s)\n\t\t}\n\t}\n\tv.Slots = kept\n\tv.Hardened = true' \
  $'\t\t\tif s.Kind == "recovery" {\n\t\t\t\ts.Transport = deviceLabel()\n\t\t\t}\n\t\t\tkept = append(kept, s)\n\t\t}\n\t}\n\tv.Slots = kept\n\tv.Hardened = true'
mutate_msg "M10 the label base64-encoded but not sealed" device_label.go \
  'return base64.StdEncoding.EncodeToString(seal(dk, []byte(label)))' 'return base64.StdEncoding.EncodeToString([]byte(label))'
mutate "M11 the checker back to a raw search for a short word" device_label_test.go \
  $'var out []string\n\tif !bytes.HasPrefix(enc, vaultMagic) {' \
  $'var out []string\n\tif bytes.Contains(enc, []byte("Ivy")) {\n\t\tout = append(out, "raw Ivy")\n\t}\n\tif !bytes.HasPrefix(enc, vaultMagic) {'
mutate "M12 the base64 decode check dropped" device_label_test.go \
  'out = append(out, fmt.Sprintf("slot %d %s does not decode as base64: %q", i, k, str))' '_ = str'
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
