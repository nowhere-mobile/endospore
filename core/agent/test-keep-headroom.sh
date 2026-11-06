#!/usr/bin/env bash
# test-keep-headroom.sh [--mutate] -- runs the KEEP-HEADROOM tests (NWP-20261104-02, Q025 [BA]); --mutate re-runs them
# against keep_headroom.go with the check broken in turn, restoring the file on exit. Each mutant must be CONVICTED
# by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
SRC=keep_headroom.go
trap '[ -f "$W/$SRC" ] && cp -f "$W/$SRC" "$SRC"; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='KeepHeadroom|AdmissionGate'

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
if xf == 'noadd':
    s = once('installHeadroom(g, base, name, pass, walletPath, add, se)', 'installHeadroom(g, base, name, pass, walletPath, 0, se)', s)
elif xf == 'nodiscount':
    s = once('est := e.bytes - e.bytes/4', 'est := e.bytes', s)
elif xf == 'nostored':
    s = once('fetchAppAddBytes(est, stored, measured, e.pkg)', 'fetchAppAddBytes(est, nil, false, e.pkg)', s)
elif xf == 'nopkgcheck':
    s = once('!validPkgName(pkg)', 'false', s)
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
mut "K1 the add ignored (only an already-over profile refuses)" noadd TestKeepHeadroomRefusesWhenTheAddWouldPushOverThePlan
mut "K2 the 25% allowance dropped" nodiscount TestKeepHeadroomFitsAnswersTheDiscountedSum TestKeepHeadroomRefusesWhenTheAddWouldPushOverThePlan
mut "K3 a held app charged its full size" nostored TestKeepHeadroomChargesOnlyTheGrowthOfAHeldApp
mut "K4 an invalid package not refused" nopkgcheck TestKeepHeadroomRefusesABadPayload
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
