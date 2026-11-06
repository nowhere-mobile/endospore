#!/usr/bin/env bash
# test-fence-seq.sh [--mutate] -- NWP-20261112-09: the publish fence's sequence fails closed (seal_fence.go). An
# unreadable or garbled `.seq` reads -1 and blocks a sampled publish, a bump is temp + rename and reports its failure,
# a lift bumps before it removes and removes nothing when it cannot bump, and an arm whose bump fails returns false.
# --mutate applies each mutant to a pristine copy of seal_fence.go (restored on exit) and requires a real `--- FAIL`:
# a mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp seal_fence.go "$W/sf.orig" || exit 2
trap 'cp "$W/sf.orig" seal_fence.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestFenceSeq|TestSealFence|TestInFlightSeal|TestSealCannot|TestDeleteArms|TestLoginLift|TestLoginLeaves|TestScopedLogin"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new>: replace the first <old> in a pristine copy of seal_fence.go, require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" res rc
  cp "$W/sf.orig" seal_fence.go
  if ! OLD="$old" NEW="$new" python3 -c "
import os
s = open('seal_fence.go').read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open('seal_fence.go','w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "TestFenceSeq" . 2>&1); rc=$?
  score_mutant "$lbl" "$rc" "$res" || FAILS=$((FAILS+1))
}
mutate "M1 an unreadable .seq reads 0" \
  'return -1 // unreadable: FAIL CLOSED' 'return 0 // unreadable: FAIL CLOSED'
mutate "M2 a .seq that does not parse reads 0" \
  'return -1 // not a decimal integer: FAIL CLOSED' 'return 0 // not a decimal integer: FAIL CLOSED'
mutate "M3 the publish check drops the -1 test" \
  'if cur < 0 || pushFenceSeq < 0 {' 'if false {'
mutate "M4 the bump writes .seq in place" \
  'return writeAtomic(filepath.Join(d, sealFenceSeqTmpName), filepath.Join(d, sealFenceSeqName), []byte(strconv.FormatInt(cur+1, 10)+"\n"))' \
  'return os.WriteFile(filepath.Join(d, sealFenceSeqName), []byte(strconv.FormatInt(cur+1, 10)+"\n"), 0o600)'
mutate "M5 the lift removes the markers before the bump" \
  $'\tif bumpSealFenceSeqLocked(d) != nil {\n\t\treturn false\n\t}\n\tremoveSealFenceMarkersLocked(d, present)\n' \
  $'\tremoveSealFenceMarkersLocked(d, present)\n\tif bumpSealFenceSeqLocked(d) != nil {\n\t\treturn false\n\t}\n'
mutate "M6 the arm ignores the bump's error" \
  $'if bumpSealFenceSeqLocked(d) != nil {\n\t\tok = false' $'if _ = bumpSealFenceSeqLocked(d); false {\n\t\tok = false'
cp "$W/sf.orig" seal_fence.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
