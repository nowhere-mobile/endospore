#!/usr/bin/env bash
# test-seal-mounts-read.sh [--mutate] -- a seal refuses, RETRY class and before it walks anything, when the mount table
# cannot be read whole (NWP-20261109-17). Plain: the SealMountsRead tests plus the PushGuard / ParseMediaOverlay tests
# that pin the refusal sites and the table parser. --mutate applies each mutant in place (pristine copies live in one
# temp root, restored after every mutant and on exit) and runs the SealMountsRead tests; each must be CONVICTED by the
# named `--- FAIL`. A mutant that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(media_seal.go main.go end_unsaved.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'TestSealMountsRead|TestPushGuard|TestParseMediaOverlay' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <mutator> <convicting test>... -- <mutator> is a python3 program run with the file's text in `s`,
# leaving the mutated text in `s`; it exits 1 when its anchor is not found exactly once.
mut() {
  local label="$1" file="$2" prog="$3" res want
  shift 3
  python3 -c "
import sys
p = sys.argv[1]
s = open(p).read()
$prog
open(p, 'w').write(s)
" "$file" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
  res=$(go test -count=1 -run 'TestSealMountsRead' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
# M1: the scanner's error is ignored, so a read error or an over-long line is a short table again.
M1='
old = "if err := sc.Err(); err != nil {"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "if err := sc.Err(); false && err != nil {")
'
# M2: an open error other than "does not exist" is answered as no overlays.
M2='
old = "return nil, err // the table exists"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "return nil, nil // the table exists")
'
# M3: pushProfile ignores the error and walks on the short map.
M3='
old = "\tif uerr != nil {\n\t\tsealRefusedWhy = \"mounts-unread\""
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "\tif false && uerr != nil {\n\t\tsealRefusedWhy = \"mounts-unread\"")
'
# M4: the reason is classed FINAL, so a transient read failure offers the sign-out without saving. Anchored on the
# function's one FINAL case clause, whatever it lists and however it wraps: other slices add FINAL reasons to it
# (NWP-20261111-01 added the locks-changed / unlock-lost four on a second line).
M4='
head = "func refusalReasonFinal(reason string) bool {\n\tswitch reason {\n\tcase \"shrink\","
end = ":\n\t\treturn true\n\t}\n\treturn false\n}"
if s.count(head) != 1:
    sys.exit(1)
i = s.index(head)
j = s.find(end, i)
if j < 0 or "\n\tcase " in s[i + len(head):j]:
    sys.exit(1)
s = s[:j] + ", \"mounts-unread\"" + s[j:]
'
mut "M1 sc.Err() ignored" media_seal.go "$M1" TestSealMountsRead_ReadErrorIsAnError TestSealMountsRead_LongLine
mut "M2 an open error answered as no overlays" media_seal.go "$M2" TestSealMountsRead_ProcMountsOpen
mut "M3 pushProfile ignores the mount-table error" main.go "$M3" TestSealMountsRead_PushRefusesBeforeAnythingIsSpent
mut "M4 mounts-unread classed FINAL" end_unsaved.go "$M4" TestSealMountsRead_ReasonIsRetry
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
