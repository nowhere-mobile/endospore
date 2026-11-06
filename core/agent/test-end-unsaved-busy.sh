#!/usr/bin/env bash
# test-end-unsaved-busy.sh [--mutate] -- END-UNSAVED and RESTART-UNSAVED say why they are busy (NWP-20261117-32):
# every BUSY the two handlers write carries one token (seal, teardown, rent, slot), so the Profile screen never says
# "A save is running" for a refusal that is not a save. The plain run is the focused end-unsaved, restart-unsaved and
# rent-gate tests; --mutate re-runs the narrow set against a COPY of the package with each BUSY arm broken in turn.
# Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
#
# Two patterns, on purpose. FULL is the plain run, in the real package dir. The copy has no ../chooser, and FULL
# selects a test that reads the chooser's source (chooserCode), so under FULL every mutant would be "convicted" by
# that test whatever it changed. Every mutant runs NARROW, and NARROW must pass on the unmutated copy first.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
FULL='^TestEndUnsaved|^TestRestartUnsaved|^TestRentGate'
NARROW='^TestEndUnsavedBusy|^TestRestartUnsavedBusy|^TestEndUnsaved_Busy|^TestRestartUnsaved_Busy|^TestRentGate'

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -timeout 300s -run "$FULL" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2

out=$(cd "$P" && go test -count=1 -timeout 300s -v -run "$NARROW" . 2>&1); rc=$?
for t in TestEndUnsavedBusy_EveryArm TestRestartUnsavedBusy_EveryArm TestEndUnsavedBusy_Source; do
  [[ "$out" == *"--- PASS: $t "* ]] || { rc=1; echo "  baseline: $t did not pass"; }
done
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" | tail -n 30
  echo "FAILED: the narrow pattern does not pass on the unmutated copy -- a mutant's --- FAIL would prove nothing"
  exit 1
fi
echo "== baseline: the narrow pattern passes on the unmutated copy"

fails=0 total=0
# mut <label> <python-regex> <replacement>: exactly one match in the copy's end_unsaved.go, else INERT or AMBIGUOUS;
# run NARROW there, then restore the file.
mut() {
  local label="$1" f="$P/end_unsaved.go" res rc2 ap
  total=$((total+1))
  cp "$f" "$W/orig.go" || exit 2
  ap=$(python3 - "$f" "$2" "$3" <<'PY'
import re, sys
p, pat, rep = sys.argv[1:4]
s = open(p).read()
k = len(re.findall(pat, s))
if k != 1:
    print("INERT" if k == 0 else "AMBIGUOUS (%d matches)" % k)
    sys.exit(1)
n = re.sub(pat, lambda m: m.expand(rep), s)
if n == s:
    print("INERT")
    sys.exit(1)
open(p, 'w').write(n)
print("applied")
PY
)
  if [ "$ap" != applied ]; then
    echo "  ${ap:-ERROR}     $label -- the mutation did not apply"; fails=$((fails+1))
  else
    res=$(cd "$P" && go test -count=1 -timeout 300s -run "$NARROW" . 2>&1); rc2=$?
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then
      echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [ "$rc2" -ne 0 ] && [[ "$res" == *'--- FAIL'* ]]; then
      echo "  convicted $label"
    elif [ "$rc2" -eq 0 ]; then
      echo "  SURVIVED  $label"; fails=$((fails+1))
    else
      echo "  BROKEN    $label -- no --- FAIL line (rc=$rc2)"; tail -n 15 <<<"$res"; fails=$((fails+1))
    fi
  fi
  cp "$W/orig.go" "$f" || exit 2
}

EU='end-unsaved user %s: BUSY -- '
RU='restart-unsaved user %s: BUSY -- '
mut "B1 END-UNSAVED's seal arm answers a bare BUSY" \
  "(${EU}a seal is running or queued[^\n]*\n\t\tfmt\.Fprint\(conn, )\"BUSY seal\\\\n\"" '\1"BUSY\\n"'
mut "B2 END-UNSAVED's teardown arm answers a bare BUSY" \
  "(${EU}a seal is running or queued[^\n]*\n[^\n]*\n\t\treturn\n\t\}\n\tif why := endUnsavedBlocked\(uid\); why != \"\" \{\n[^\n]*\n\t\tfmt\.Fprint\(conn, )\"BUSY teardown\\\\n\"" '\1"BUSY\\n"'
mut "B3 END-UNSAVED's rent arm answers a bare BUSY" \
  "(${EU}a rent payment[^\n]*\n\t\tfmt\.Fprint\(conn, )\"BUSY rent\\\\n\"" '\1"BUSY\\n"'
mut "B4 END-UNSAVED's slot arm answers a bare BUSY" \
  "(${EU}the worker slot stayed held[^\n]*\n\t\tfmt\.Fprint\(conn, )\"BUSY slot\\\\n\"" '\1"BUSY\\n"'
mut "B5 END-UNSAVED's teardown re-check answers a bare BUSY" \
  "(dropSE := [^\n]*\n\tif why := endUnsavedBlocked\(uid\); why != \"\" \{\n[^\n]*\n\t\tfmt\.Fprint\(conn, )\"BUSY teardown\\\\n\"" '\1"BUSY\\n"'
mut "B6 RESTART-UNSAVED's seal arm answers a bare BUSY" \
  "(\tif sealAnnounced\(\) \{\n\t\tfmt\.Fprint\(conn, )\"BUSY seal\\\\n\"" '\1"BUSY\\n"'
mut "B7 RESTART-UNSAVED's teardown arm answers a bare BUSY" \
  "(${RU}%s\\\\n\", uid, why\)\n\t\tfmt\.Fprint\(conn, )\"BUSY teardown\\\\n\"" '\1"BUSY\\n"'
mut "B8 RESTART-UNSAVED's rent arm answers a bare BUSY" \
  "(${RU}a rent payment[^\n]*\n\t\tfmt\.Fprint\(conn, )\"BUSY rent\\\\n\"" '\1"BUSY\\n"'
mut "B9 RESTART-UNSAVED's slot arm answers a bare BUSY" \
  "(\tcase <-time\.After\(endUnsavedSlotWait\):\n\t\tfmt\.Fprint\(conn, )\"BUSY slot\\\\n\"" '\1"BUSY\\n"'
mut "B10 RESTART-UNSAVED's seal re-check passes a bare BUSY" \
  'restartRefused\(conn, uid, "BUSY seal",' 'restartRefused(conn, uid, "BUSY",'
mut "B11 RESTART-UNSAVED's teardown re-check passes a bare BUSY" \
  'restartRefused\(conn, uid, "BUSY teardown",' 'restartRefused(conn, uid, "BUSY",'
mut "B12 END-UNSAVED's rent arm answered as seal" \
  "(${EU}a rent payment[^\n]*\n\t\tfmt\.Fprint\(conn, )\"BUSY rent\\\\n\"" '\1"BUSY seal\\n"'
mut "B13 RESTART-UNSAVED's rent arm answered as seal" \
  "(${RU}a rent payment[^\n]*\n\t\tfmt\.Fprint\(conn, )\"BUSY rent\\\\n\"" '\1"BUSY seal\\n"'
[ "$fails" -eq 0 ] && echo "== all $total mutations convicted" || { echo "== $fails of $total mutation(s) not convicted"; exit 1; }
