#!/usr/bin/env bash
# test-roam-out-gone.sh [--mutate] -- ROAM-OUT is deleted (NWP-20261201-33; DECIDED 2026-11-06, h60 #12): the verb and
# its handler are gone and the verb meets the legacy-login fallthrough. The plain run also holds the suites this
# removal edited. --mutate re-runs TestRoamOutVerbIsGone against a COPY of the package with the verb brought back in
# four ways. Each mutant must be CONVICTED by a real `--- FAIL` that carries its own assertion's text; one that fails
# to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestRoamOutVerbIsGone|TestSeedMediaVerbIsGone|TestLogoutGateHonoursBothMarkers|TestAnEmptySignInIsLocalAndNeverSeals|TestUiderrorsFloor_|TestTheWalletRetryAndProofCallSites|TestBestEffortPanic_|TestAdmissionGateHasOneCaller|TestNoLogPrintsAProfileNameOutsideQuotes'

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/agent"
cp -a . "$P" || exit 2
fails=0
mut() { # mut <label> <literal anchor> <text inserted before it> <convicting failure text>...
  local label=$1 anchor=$2 insert=$3 res want missing=""
  shift 3
  cp -f "$P/main.go" "$W/orig" || return 1
  python3 - "$P/main.go" "$anchor" "$insert" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import sys
p, anchor, ins = sys.argv[1:4]
anchor = anchor.encode().decode('unicode_escape')
ins = ins.encode().decode('unicode_escape')
s = open(p, encoding='utf-8').read()
if s.count(anchor) != 1: sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(anchor, ins + anchor))
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run 'TestRoamOutVerbIsGone$' -v . 2>&1)
  for want in "$@"; do
    grep -qF -- "$want" <<<"$res" || missing=$want
  done
  if grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  elif grep -qE '^\s*--- FAIL' <<<"$res" && [ -z "$missing" ]; then echo "  convicted $label"
  else echo "  SURVIVED  $label -- no --- FAIL with: ${missing:-the assertions named}"; fails=$((fails+1)); fi
  cp -f "$W/orig" "$P/main.go"
}
LOGOUT='if name == "LOGOUT" {\n\t\tcaptureWifiMirror(dest)'
mut "M1 the arm restored" "$LOGOUT" 'if name == "ROAM-OUT" {\n\t\tfmt.Fprint(conn, "OK\\n")\n\t\treturn\n\t}\n\t' 'handleLogin still dispatches "ROAM-OUT"' 'ROAM-OUT reply "OK", want BLANK'
mut "M2 the handler back" 'func rebootNow(reason string) {' 'func handleRoamOut(conn net.Conn, dest string) {}\n\n' 'main.go still names handleRoamOut'
mut "M3 a hidden arm ends the session" "$LOGOUT" 'if name == "ROAM"+"-OUT" {\n\t\tos.Remove(filepath.Join(dest, ".roamsession"))\n\t\tfmt.Fprint(conn, "BLANK\\n")\n\t\treturn\n\t}\n\t' 'the live session marker did not survive'
mut "M4 a hidden arm reboots" "$LOGOUT" 'if name == "ROAM"+"-OUT" {\n\t\trebootNow("x")\n\t\tfmt.Fprint(conn, "BLANK\\n")\n\t\treturn\n\t}\n\t' 'ROAM-OUT reached rebootNow'
[ "$fails" -eq 0 ] && echo "== all 4 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
