#!/usr/bin/env bash
# test-strict-arg-line.sh [--mutate] -- NWP-20261119-29: ROLLBACK answers ERR for anything but a positive decimal
# version, and REMOVE-FIDO2-KEY answers ERR when its credID line did not arrive with its LF, so a request whose argument
# line never arrived neither rolls the head back nor strips every security key. Runs strict_arg_line_test.go; --mutate
# applies each mutant to main.go in place (restored on exit) and requires a real `--- FAIL`: a mutant that does not
# apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestStrictArgLine'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

cp main.go "$W/main.go.orig" || exit 2
FAILS=0
# mutate <label> <old> <new>: replace the one occurrence of old in a pristine main.go, require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" o r
  cp -f "$W/main.go.orig" main.go
  if ! python3 - "$old" "$new" <<'PY'
import sys
old, new = sys.argv[1], sys.argv[2]
s = open('main.go').read()
if s.count(old) != 1:
    raise SystemExit('mutant did not apply: %d matches' % s.count(old))
open('main.go', 'w').write(s.replace(old, new, 1))
PY
  then
    echo "  BROKEN    $lbl -- the mutant did not apply"; FAILS=$((FAILS+1)); cp -f "$W/main.go.orig" main.go; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1); r=$?
  score_mutant "$lbl" "$r" "$o" || FAILS=$((FAILS+1))
  cp -f "$W/main.go.orig" main.go
}
echo "== mutations =="
mutate "S1: handleRollback's refusal removed" \
  'if perr != nil || ver == 0 {' 'if false && (perr != nil || ver == 0) {'
mutate "S2: the refusal accepts 0" \
  'if perr != nil || ver == 0 {' 'if perr != nil {'
mutate "S3: the ROLLBACK arm passes the value whatever ReadString's error" \
  $'if err != nil {\n\t\t\tvl = ""' $'if false && err != nil {\n\t\t\tvl = ""'
mutate "S4: the REMOVE-FIDO2-KEY arm ignores ReadString's error" \
  $'if err != nil {\n\t\t\tfmt.Fprint(os.Stderr, "[logind] remove-fido2-key: refused' \
  $'if false && err != nil {\n\t\t\tfmt.Fprint(os.Stderr, "[logind] remove-fido2-key: refused'
[ "$FAILS" = 0 ] || { echo "== $FAILS mutant(s) not convicted"; exit 1; }
echo "== 4 mutants convicted"
