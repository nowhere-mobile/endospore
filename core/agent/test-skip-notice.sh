#!/usr/bin/env bash
# test-skip-notice.sh [--mutate] -- NWP-20261123-22: the WRITE side of the next-sign-in skip notice (skip_notice.go).
# Both pushProfile tombstone exits write a notice at hex(HMAC(dk, "nowhere-skip-notice-v1")), sealed under the DK,
# only when the restored vault's recovery entry point still resolves or it names none (h53 #2, 2026-11-02).
# Backlog row "`pushProfile`'s tombstone skips report "Saved" and the next login tells nobody (#119)".
# --mutate applies each mutant to a pristine copy of its file (every copy restored on exit) and requires a real
# `--- FAIL`: a mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES="skip_notice.go main.go"
for f in $FILES; do cp "$f" "$W/$f.orig" || exit 2; done
trap 'for f in $FILES; do cp "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestSkipNotice|Tombstone|TestSealRecoversLostHead|TestNoLogPrintsAProfileNameOutsideQuotes"
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
mutate "M1 write without the recovery check" skip_notice.go \
  'if v.RecoveryRef == "" {' 'if true || v.RecoveryRef == "" {'
mutate "M2 a failed recovery read treated as resolved" skip_notice.go \
  'if recovered(func() { b, present = getRefBytesStrict(base, v.RecoveryRef) }) != nil {' \
  'if recovered(func() { b, present = getRefBytesStrict(base, v.RecoveryRef) }) != nil { return true, "" }; if false {'
mutate "M3 the address keyed on the passphrase-derived ref, not the DK" skip_notice.go \
  'ref := skipNoticeRef(dk)' 'ref := skipNoticeRef([]byte(profileRefV2(bare, pass)))'
mutate "M4 no call at the scope exit" main.go \
  $'\t\t\twriteSkipNotice(base, profile, pass) // NWP-20261123-22: scope skip -> the next sign-in is told (h53 #2)\n' ''
mutate "M5 the DK opened from the scope's own receipt" skip_notice.go \
  'head := restoreReceiptHead(profileRefV2(bare, pass))' 'head := restoreReceiptHead(profileRefV2(profile, pass))'
mutate "M6 cap mode: no no-login session before the notice flush" skip_notice.go \
  $'\t\t\t\tcapSetSessionAttr(bare, pass, nil, true) // a no-login session: the free arm, no fold, no spend\n' $'\t\t\t\t_ = bare\n'
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
