#!/usr/bin/env bash
# test-create-code-memo.sh [--mutate] -- NWP-20261101-03 (Q048): a create whose reply was lost hands its recovery
# code over once on the retry. Runs the focused Go tests; --mutate applies each mutant to a pristine copy of
# create_code_memo.go / main.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or
# that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp create_code_memo.go "$W/memo.orig" || exit 2
cp main.go "$W/main.orig" || exit 2
trap 'cp "$W/memo.orig" create_code_memo.go; cp "$W/main.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="CreateCodeMemo"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <old> <new>: replace the first <old> in a pristine copy of <file>, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" old="$3" new="$4" res
  cp "$W/memo.orig" create_code_memo.go
  cp "$W/main.orig" main.go
  if ! F="$f" OLD="$old" NEW="$new" python3 -c "
import os
f = os.environ['F']
s = open(f).read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "C1 take does not delete" create_code_memo.go '	delete(createCodeMemo, k)
' ''
mutate "C2 the TTL check removed" create_code_memo.go 'if !createCodeMemoNow().Before(e.until) {' 'if false {'
mutate "C3 EXISTS ignores the memo" main.go 'if w := takeCreatedCode(name, pass); w != "" {' 'if w := ""; w != "" {'
mutate "C4 handleRoamIn does not forget" main.go 'forgetCreatedCodes() // NWP-20261101-03 (Q048): a sign-in ends' '// NWP-20261101-03 (Q048): a sign-in ends'
mutate "C5 purgeExpiredLocked does nothing" create_code_memo.go 'func purgeExpiredLocked(now time.Time) {
' 'func purgeExpiredLocked(now time.Time) {
	if true {
		return
	}
'
mutate "C6 purge comparison inverted" create_code_memo.go '		if !now.Before(e.until) {
			delete(createCodeMemo, key)' '		if now.Before(e.until) {
			delete(createCodeMemo, key)'
mutate "C7 syncLoop does not purge" main.go '		purgeExpiredCreatedCodes()
' ''
mutate "C8 remember does not purge" create_code_memo.go '	purgeExpiredLocked(createCodeMemoNow()) //' '	//'
cp "$W/memo.orig" create_code_memo.go
cp "$W/main.orig" main.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
