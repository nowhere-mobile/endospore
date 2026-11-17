#!/usr/bin/env bash
# test-lastsave-verb.sh [--mutate] -- NWP-20261205-01: GET-LASTSAVE (lastsave_verb.go) answers the live session's own
# user, and no other caller, with the agent slice's $STATE/lastsave.<uid> line, else NONE. Backlog row "The scopes
# advance INDEPENDENTLY with no consistency rule, so a partial seal leaves the stored profile internally skewed" (h58 #1).
# --mutate applies each mutant to a pristine copy of its file (every copy restored on exit) and requires a real
# `--- FAIL`: a mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES="lastsave_verb.go main.go"
for f in $FILES; do cp "$f" "$W/$f.orig" || exit 2; done
trap 'for f in $FILES; do cp "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestLastSaveVerb|TestConcurrentSafeCmd|TestNoLogPrintsAProfileNameOutsideQuotes"
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
# L1: convicted by TestLastSaveVerbScoped's "caller in user 11".
mutate "L1 the sessionCaller check removed" lastsave_verb.go \
  'case !sessionCaller(conn, uid):' 'case false && !sessionCaller(conn, uid):'
# L2: convicted by TestLastSaveVerbScoped's "offline session".
mutate "L2 the localOnlySession check removed" lastsave_verb.go \
  'case localOnlySession(dest):' 'case false && localOnlySession(dest):'
# L3: convicted by TestLastSaveVerbWire's "257 bytes".
mutate "L3 the size bound removed" lastsave_verb.go \
  'if len(b) > 256 {' 'if false && len(b) > 256 {'
# L4: convicted by TestLastSaveVerbWire's "two lines".
mutate "L4 the single-line check removed" lastsave_verb.go \
  'if strings.ContainsAny(line, "\r\n") {' 'if false && strings.ContainsAny(line, "\r\n") {'
# L5: convicted by TestLastSaveVerbWire's "v=2".
mutate "L5 the v=1 prefix check removed" lastsave_verb.go \
  'if !strings.HasPrefix(line, "v=1 unsaved=") {' 'if false && !strings.HasPrefix(line, "v=1 unsaved=") {'
# L6: convicted by TestLastSaveVerbWire's "uid 1a".
mutate "L6 the uid digit check removed" lastsave_verb.go \
  'strings.Trim(uid, "0123456789") != ""' 'false'
# L7: convicted by TestLastSaveVerbLockFree and TestConcurrentSafeCmd.
mutate "L7 the concurrentSafeCmd entry removed" main.go \
  '		"GET-LASTSAVE",
' ''
# L8: convicted by TestLastSaveVerbHasALoginArm.
mutate "L8 the dispatch arm renamed" main.go \
  'if name == "GET-LASTSAVE" {' 'if name == "GET-LASTSAVE-X" {'
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
