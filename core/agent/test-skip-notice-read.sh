#!/usr/bin/env bash
# test-skip-notice-read.sh [--mutate] -- NWP-20261125-19: the READ side's agent half of the next-sign-in skip notice
# (skip_notice.go). GET-SKIP-NOTICE answers a notice later than the profile's shown record, to the session's own user
# only; SKIP-NOTICE-SHOWN records it shown at hex(HMAC(dk, "nowhere-skip-notice-shown-v1")) and never lowers it.
# Backlog row "`pushProfile`'s tombstone skips report "Saved" and the next login tells nobody (#119)" (h50 #6).
# --mutate applies each mutant to a pristine copy of its file (every copy restored on exit) and requires a real
# `--- FAIL`: a mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES="skip_notice.go"
for f in $FILES; do cp "$f" "$W/$f.orig" || exit 2; done
trap 'for f in $FILES; do cp "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="SkipNotice|TestNoLogPrintsAProfileNameOutsideQuotes"
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
mutate "M1 the Time comparison inverted" skip_notice.go \
  'show = rec.Time > shown.Time' 'show = rec.Time < shown.Time'
mutate "M2 the shown write keyed by the notice's info string" skip_notice.go \
  'm.Write([]byte(skipNoticeShownInfo))' 'm.Write([]byte(skipNoticeInfo))'
mutate "M3 the sessionCaller check removed" skip_notice.go \
  'if !sessionCaller(conn, uid) {' 'if false && !sessionCaller(conn, uid) {'
mutate "M4 the lower-time guard removed" skip_notice.go \
  'if have && cur.Time >= t {' 'if false && have && cur.Time >= t {'
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
