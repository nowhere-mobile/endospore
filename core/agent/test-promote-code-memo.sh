#!/usr/bin/env bash
# test-promote-code-memo.sh [--mutate] -- NWP-20261116-04 (h46 #7): a Save to your store whose PROMOTE2 reply was lost
# hands its recovery words over once on the repeat Save. Runs the focused Go tests; --mutate applies each mutant to a
# pristine copy of create_code_memo.go / main.go (restored on exit) and requires a real `--- FAIL`: a mutant that does
# not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp create_code_memo.go "$W/memo.orig" || exit 2
cp main.go "$W/main.orig" || exit 2
trap 'cp "$W/memo.orig" create_code_memo.go; cp "$W/main.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestPromoteCodeMemo"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <old> <new> [<old2> <new2>]: replace the first match of each <old> in a pristine copy of
# <file>, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" res
  shift 2
  cp "$W/memo.orig" create_code_memo.go
  cp "$W/main.orig" main.go
  if ! F="$f" python3 -c "
import os, sys
f = os.environ['F']
s = open(f).read()
a = sys.argv[1:]
for i in range(0, len(a), 2):
    t = s.replace(a[i], a[i+1], 1)
    if t == s: raise SystemExit('mutant did not apply')
    s = t
open(f,'w').write(s)" "$@"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "M1 remember after the reply" main.go '	// NWP-20261116-04 (h46 #7): remember the words before any reply, so a lost reply can be handed over.
	rememberPromotedCode(name, pass, recovery)
' '' '	fmt.Fprintf(conn, "OK RECOVERY %s\n", recovery)
' '	fmt.Fprintf(conn, "OK RECOVERY %s\n", recovery)
	rememberPromotedCode(name, pass, recovery)
'
mutate "M2 the shared create prefix" create_code_memo.go '"nowhere-promote-memo\x00"' '"nowhere-create-memo\x00"'
mutate "M3 handOver ignored" main.go 'if handOver {' 'if true {'
mutate "M4 take without delete" create_code_memo.go '	delete(createCodeMemo, k)
' ''
cp "$W/memo.orig" create_code_memo.go
cp "$W/main.orig" main.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
