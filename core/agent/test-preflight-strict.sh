#!/usr/bin/env bash
# test-preflight-strict.sh [--mutate] -- restore-preflight reads each destination ref strictly: a read the store will
# not answer (a fresh-cap 403 included) is UNREADABLE and blocks; a 404 is still absent and an empty object a
# tombstone (NWP-20261102-16). --mutate copies the package into the temp root for every mutant, applies the mutant to
# THAT copy and runs the same focused set there; each must be CONVICTED by the named `--- FAIL`. The working tree is
# never edited. A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='TestPreflight|TestOnlyADifferingHeadBlocksARestore|TestTheReportNamesTheRollbackDirection|TestAnUnreadableHeadIsNotTreatedAsAgreement|TestASafeDestinationStillReportsWhatItSaw|TestRestoringOverADeleteIsAllowedButNamed'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want d
  shift 4
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R "$SRC/." "$d/"
  python3 - "$d/$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(cd "$d" && go test -count=1 -run "$FOCUS" -v . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  rm -rf "$d"
}
F=restore_preflight.go
mut "P1 the preflight back on capGet" $F 'getRefBytesStrict(base, name)' 'getRefBytes(base, name)' TestPreflightFresh403IsUnreadable
mut "P2 unreadable not counted in Blocking" $F 'rep.Blocking++ // an unreadable head blocks: it is never evidence that the destination is empty' '// unreadable no longer blocks' TestPreflightFresh403IsUnreadable
mut "P3 a failed read taken as absent" $F 'case err != nil:' 'case err != nil && present:' TestPreflightFresh403IsUnreadable
mut "P4 a 404 read as unreadable" $F $'case !present:\n\t\t\tv.State = "absent"' $'case !present:\n\t\t\tv.State = "unreadable"\n\t\t\trep.Blocking++' TestPreflight404IsAbsent
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
