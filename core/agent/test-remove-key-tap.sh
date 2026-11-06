#!/usr/bin/env bash
# test-remove-key-tap.sh [--mutate] -- NWP-20261127-02 (h53 #3): removing a security key needs a FRESH tap of a remaining
# key, or of the key itself when it is the last one; the hmac cached at sign-in never confirms it. Runs
# remove_key_tap_test.go (TestRemoveKeyTap*: removeFido2KeyTapped, and the REMOVE-FIDO2-KEY arm with roamd's fido2adopt
# stubbed). --mutate applies each mutant to fido2.go or main.go in place (restored on exit) and requires a real
# `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
# What it does NOT prove: a removal on a handset (the USB tap itself is roamd's fido2adopt, run by the merger on lynx).
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'for f in fido2.go main.go; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestRemoveKeyTap'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

cp fido2.go "$W/fido2.go.orig" || exit 2
cp main.go "$W/main.go.orig" || exit 2
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
[ "$FAILS" = 0 ] || { echo "== $FAILS mutant(s) not convicted"; exit 1; }
echo "== $N mutants convicted"
