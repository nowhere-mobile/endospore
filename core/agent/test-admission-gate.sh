#!/usr/bin/env bash
# test-admission-gate.sh [--mutate] -- runs the one-admission-gate tests (NWP-20261103-12); --mutate re-runs them
# against billing.go with the gate broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
SRC=billing.go
trap '[ -f "$W/$SRC" ] && cp -f "$W/$SRC" "$SRC"; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='AdmissionGate|Headroom'

out=$(go test -count=1 -run "$RUN_RE" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/$SRC"
fails=0
mut() { # mut <label> <transform> <convicting test>...
  local label="$1" xf="$2" res want miss=""
  shift 2
  python3 - "$SRC" "$xf" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$SRC" "$SRC"; return; }
import sys
p, xf = sys.argv[1:3]
s = open(p).read()
def once(a, b, text):
    if text.count(a) != 1:
        sys.exit(1)
    return text.replace(a, b)
if xf == 'onescope':
    i = s.find('func installHeadroom(')
    j = s.find('\n}\n', i)
    if i < 0 or j < 0:
        sys.exit(1)
    span = once('\trefs, measured := profileFootprint(base, name, pass, se)\n',
                '\trefs := map[string]int64{}\n\tmeasured := !scopeFootprint(base, name, pass, se, refs)\n', s[i:j])
    s = s[:i] + span + s[j:]
elif xf == 'entitled':
    s = once('\tcovered := ent.coverage()\n', '\tcovered := ent.EntitledBytes\n', s)
elif xf == 'noadd':
    s = once('if over := usedBytes + addBytes - coveredBytes; over > 0 {', 'if over := usedBytes - coveredBytes; over > 0 {', s)
else:
    sys.exit(1)
open(p, 'w').write(s)
PY
  res=$(go test -count=1 -run "$RUN_RE" -v . 2>&1)
  if [[ "$res" == *"[build failed]"* ]]; then
    echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      [[ "$res" == *"--- FAIL: $want"* ]] || miss="$miss $want"
    done
    if [ -z "$miss" ]; then echo "  convicted $label"
    else echo "  SURVIVED  $label -- not failed by:$miss"; fails=$((fails+1)); fi
  fi
  cp -f "$W/$SRC" "$SRC"
}
mut "A1 used summed over the bare scope only" onescope TestAdmissionGateSumsEveryScope TestAdmissionGateLapsedIsReadOnlyOverTheFreeAllowance TestAdmissionGateLapsedRefusesByTheAddAlone
mut "A2 coverage() replaced by EntitledBytes" entitled TestAdmissionGateSumsEveryScope TestAdmissionGateLapsedIsReadOnlyOverTheFreeAllowance TestAdmissionGateLapsedRefusesByTheAddAlone
mut "A3 headroomShortBytes' add term dropped" noadd TestAdmissionGateLapsedRefusesByTheAddAlone
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
