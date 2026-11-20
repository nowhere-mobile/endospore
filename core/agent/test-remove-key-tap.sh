#!/usr/bin/env bash
# test-remove-key-tap.sh [--mutate] -- NWP-20261127-02 (h53 #3): removing a security key needs a FRESH tap of a remaining
# key, or of the key itself when it is the last one; the hmac cached at sign-in never confirms it. Runs
# remove_key_tap_test.go (TestRemoveKeyTap*: removeFido2KeyTapped, and the REMOVE-FIDO2-KEY arm with roamd's fido2adopt
# stubbed), and remove_key_nfc_test.go (TestRemoveKeyNFC*: REMOVE-FIDO2-KEY-NFC with nfcAssert stubbed,
# NWP-20261208-16, h57 #6). --mutate applies each mutant to fido2.go, main.go or fido2_nfc_remove.go in place (restored
# on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never
# a conviction.
# What it does NOT prove: a removal on a handset (the USB tap itself is roamd's fido2adopt, run by the merger on lynx),
# nor an NFC removal on a handset (no chooser sends REMOVE-FIDO2-KEY-NFC yet).
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'for f in fido2.go main.go fido2_nfc_remove.go; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestRemoveKeyTap|TestRemoveKeyNFC'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

cp fido2.go "$W/fido2.go.orig" || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp fido2_nfc_remove.go "$W/fido2_nfc_remove.go.orig" || exit 2
FAILS=0
N=0
# mutate <label> <file> <old> <new>: replace the one occurrence of old in a pristine file, require a real --- FAIL
mutate() {
  local lbl="$1" file="$2" old="$3" new="$4" o r
  N=$((N+1))
  cp -f "$W/$file.orig" "$file"
  if ! python3 - "$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if s.count(old) != 1:
    raise SystemExit('mutant did not apply: %d matches' % s.count(old))
open(path, 'w').write(s.replace(old, new, 1))
PY
  then
    echo "  BROKEN    $lbl -- the mutant did not apply"; FAILS=$((FAILS+1)); cp -f "$W/$file.orig" "$file"; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1); r=$?
  score_mutant "$lbl" "$r" "$o" || FAILS=$((FAILS+1))
  cp -f "$W/$file.orig" "$file"
}
echo "== mutations =="
mutate "M1: the tap check skipped" fido2.go \
  $'if fido2DKWith(&only, passKEK, tap) == nil {\n\t\treturn false, errKeyTapWrong' \
  $'if false && fido2DKWith(&only, passKEK, tap) == nil {\n\t\treturn false, errKeyTapWrong'
mutate "M2: the permitted set keeps the named key while others remain" fido2.go \
  $'if s.CredID != credIDb64 {\n\t\t\tothers' $'if true {\n\t\t\tothers'
mutate "M3: the USB arm calls removeFido2Key directly" main.go \
  'removeFido2KeyTapped("s3", nm, ps, cid, tap, seFromSession(dest), dest)' \
  'removeFido2Key("s3", nm, ps, cid, seFromSession(dest), dest)'
mutate "M4: the arm's mtime check dropped" main.go \
  'if fi, err := os.Stat(stash); err == nil && fi.ModTime().After(before) {' \
  'if fi, err := os.Stat(stash); err == nil && (fi.ModTime().After(before) || true) {'
mutate "M5: the missing-tap refusal dropped" fido2.go \
  $'if len(tap) == 0 {\n\t\treturn false, errKeyTapMissing' $'if false {\n\t\treturn false, errKeyTapMissing'
mutate "M6: the arm answers ERR for a wrong key" main.go \
  'fmt.Fprint(conn, "ERR-WRONGKEY\n")' 'fmt.Fprint(conn, "ERR\n")'
# M7-M14: REMOVE-FIDO2-KEY-NFC (NWP-20261208-16), each convicted by the TestRemoveKeyNFC case named.
# M7 -> N8: an unterminated credID line reaches the session read and answers ERR-NOSESSION, not ERR.
mutate "M7: the NFC verb's strict line read ignores its error" fido2_nfc_remove.go \
  $'cid, err := r.ReadString(\'\\n\')\n\tif err != nil {' $'cid, err := r.ReadString(\'\\n\')\n\tif false && err != nil {'
# M8 -> N3: a never-enrolled tap is stashed over A's hmac and answers ERR-WRONGKEY, not ERR-NOKEY.
mutate "M8: the head check before the stash skipped" fido2_nfc_remove.go \
  'if fido2DKWith(v, deriveKey(nm, ps), h) == nil {' 'if false && fido2DKWith(v, deriveKey(nm, ps), h) == nil {'
# M9 -> N2 (a tap of the key being removed answers OK true, not ERR-WRONGKEY) and N9 (the untapped removal called).
mutate "M9: the NFC verb calls removeFido2Key directly" fido2_nfc_remove.go \
  'removeFido2KeyTapped(base, nm, ps, cid, h, seFromSession(dest), dest)' \
  'removeFido2Key("s3", nm, ps, cid, seFromSession(dest), dest)'
# M10 -> N1: .fido2hmac still holds A's hmac after A is removed by a tap of B.
mutate "M10: the stash after a good tap dropped" fido2_nfc_remove.go \
  'if err := stashFido2Hmac(dest, h); err != nil {' 'if err := error(nil); err != nil {'
# M11 -> N6: .fido2hmac and NOWHERE_FIDO2_HMAC are still there after the last key went.
mutate "M11: the NFC verb's last-key purge dropped" fido2_nfc_remove.go 'if !still {' 'if false && !still {'
# M12 -> N2: a tap of the key being removed answers ERR, not ERR-WRONGKEY.
mutate "M12: the NFC verb answers ERR for a wrong key" fido2_nfc_remove.go \
  'fmt.Fprint(conn, "ERR-WRONGKEY\n")' 'fmt.Fprint(conn, "ERR\n")'
# M13 -> N1: nfcAssert gets one slot, want both enrolled slots.
mutate "M13: nfcAssert given only the permitted slots" fido2_nfc_remove.go \
  'nfcAssert(&nfcShuttle{conn: conn, r: r}, slots)' \
  'nfcAssert(&nfcShuttle{conn: conn, r: r}, listFido2Slots(&vault{Slots: permittedRemoveSlots(v, cid)}))'
# M14 -> N9: no conn.SetDeadline of 120 s or more between nfcAssert and daemonVaultOp (#744).
mutate "M14: the post-assert SetDeadline dropped" fido2_nfc_remove.go \
  'conn.SetDeadline(time.Now().Add(130 * time.Second))' '_ = conn'
[ "$FAILS" = 0 ] || { echo "== $FAILS mutant(s) not convicted"; exit 1; }
echo "== $N mutants convicted"
