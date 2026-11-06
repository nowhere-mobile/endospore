#!/usr/bin/env bash
# test-stranded-push.sh [--mutate] -- a push no slot opens, on a session whose restore receipt names a readable vault,
# is refused as locks-changed[-key] or unlock-lost[-key] and classed FINAL (NWP-20261111-01, Q016, decided
# 2026-10-20); with no receipt it still fails as before. Plain: the focused set. --mutate copies the package into the
# temp root for every mutant, applies the mutant to THAT copy and runs the same focused set there; each must be
# CONVICTED by the named `--- FAIL`. The working tree is never edited. A mutant that fails to apply or to compile
# counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='Stranded|RefusalReasonFinal|PushGuard'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> [<old> <new>]... -- <convicting test>... (every occurrence of old is replaced)
mut() {
  local label="$1" file="$2" res want d
  local -a pairs=()
  shift 2
  while [ $# -gt 0 ] && [ "$1" != -- ]; do pairs+=("$1"); shift; done
  shift
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R "$SRC/." "$d/"
  python3 - "$d/$file" "${pairs[@]}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p = sys.argv[1]
rest = sys.argv[2:]
s = open(p).read()
for old, new in zip(rest[0::2], rest[1::2]):
    if s.count(old) < 1:
        sys.exit(1)
    s = s.replace(old, new)
open(p, 'w').write(s)
PY
  res=$(cd "$d" && go test -count=1 -run "$FOCUS" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  rm -rf "$d"
}
C1=TestStrandedPush_C1_StrandedReasonTable
P1=TestStrandedPush_P1_AKeyEnrolledElsewhereIsLocksChangedKey
P2=TestStrandedPush_P2_UnchangedLocksAreUnlockLost
P3=TestStrandedPush_P3_NoReceiptKeepsTheOldFailure
P4=TestStrandedPush_P4_EachReasonTravelsAndLicensesTheExit
RF=TestRefusalReasonFinal_EachGuardIsClassed
mut "M1 the arm still fails: a push no slot opens is ERR-PUSH whatever the receipt says" main.go 'if why == "" {' 'if why == "" || true {' -- "$P1" "$P2"
mut "M2 strandedReason ignores Wrapped: a rotation reads as unlock-lost" stranded_push.go 's.Kind, s.Wrapped, s.CredID' 's.Kind, "", s.CredID' -- "$C1"
mut "M3 no -key suffix: a head a key opens is not told apart" stranded_push.go 'why += "-key"' 'why += ""' -- "$C1" "$P1"
mut "M4 refusalReasonFinal omits locks-changed: classed RETRY" end_unsaved.go '"locks-changed", "locks-changed-key"' '"locks-changed-key"' -- "$RF" "$P4"
mut "M5 the arm refuses when the receipt is empty" main.go $'if why == "" {\n\t\t\t\t\tfail("push: no slot opens (pass + secure-element + security-key all failed)")' $'if why == "" {\n\t\t\t\t\twhy = "unlock-lost"' -- "$P3"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
