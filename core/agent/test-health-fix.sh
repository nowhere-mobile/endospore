#!/usr/bin/env bash
# test-health-fix.sh [--mutate] -- runs health_fix_test.go (NWP-20261201-10: HEALTH-FIX and GET-HEALTH-FIX, a health
# notice's Fix); --mutate re-runs it against a COPY of the package with each part broken in turn. Each mutant must be
# CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'HealthFix|^TestGatePollersNeverWaitOnTheSession$' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement> <the test that must convict it>: apply to the copy, run the suite
# there, require that test's own `--- FAIL`, then restore the file.
mut() {
  local label="$1" f="$2" conv="$5" res
  cp "$P/$f" "$W/orig.go"
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p,encoding='utf-8').read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w',encoding='utf-8').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *"--- FAIL: $conv"* ]]; then echo "  convicted $label (by $conv)"
    else echo "  SURVIVED  $label (wanted --- FAIL: $conv)"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "H1 the rule's op becomes the sign-out op" health_fix.go \
  '"play-push-frozen": "playrestart"' '"play-push-frozen": "out"' TestHealthFixNeverSignsOut
mut "H2 the caller check is removed" health_fix.go \
  'if !gateCallerOK\(peer\) && !\(peer >= 0 && daySummaryUIDOK\(uid\) && strconv\.Itoa\(peer/100000\) == uid\) \{' \
  'if false && peer == strconv.IntSize {' TestHealthFixCallers
mut "H3 the Fix time is not recorded" health_fix.go \
  'healthFixRecord\(uid, id, healthFixNow\(\)\)' '_ = healthFixNow' TestGetHealthFixAges
mut "H4 the Fix time is recorded on any reply" health_fix.go \
  'if word == "OK" \{' 'if word != "" {' TestHealthFixBusyIsNotRecorded
mut "H5 a new session uid keeps the earlier Fixes" health_fix.go \
  'if healthFixState\.uid != uid \{' 'if false {' TestGetHealthFixNewUIDForgets
mut "H6 GET-HEALTH-FIX answers any caller" health_fix.go \
  'if !gateCallerOK\(ownerPeerUID\(conn\)\) \{' 'if false && ownerPeerUID(conn) == 0 {' TestGetHealthFixGateOnly
mut "H7 the production worker sends a pass" health_fix.go \
  'triggerRoamWorker\(dest, op, name, "", uid, "", nil\)' 'triggerRoamWorker(dest, op, name, "x", uid, "", nil)' TestHealthFixProductionWorkerCarriesNoPass
mut "H8 laneFor no longer sends playrestart to the RO lane" main.go \
  'case "playrestart":\n\t\t// NWP-20261201-10: a health notice.s Fix, one .am force-stop. of Play services in the session.s user\.\n\t\treturn laneRO\n\t' '' TestHealthFixNeverSignsOut
mut "H9 workerWaitCap has no playrestart case" main.go \
  'case "playrestart":\n\t\t// NWP-20261201-10: a tap on a health notice.s Fix.*?return 10 \* time\.Second\n\t' '' TestHealthFixNeverSignsOut
mut "H10 the verbs wait on sessionMu" main.go \
  'case "HEALTH-FIX", "GET-HEALTH-FIX":\n\t\treturn true\n\t' '' TestHealthFixVerbsRunWithoutSessionMu
mut "H11 the session's own user is refused" health_fix.go \
  'strconv\.Itoa\(peer/100000\) == uid' 'strconv.Itoa(peer) == uid' TestHealthFixCallers
mut "H12 the lock fence ignores a verb's arm" gate_poll_lockfree_test.go \
  'return !safe && \(armed \|\| !awaitingArm\)' 'return !safe && !awaitingArm' TestHealthFixAwaitingArmKeepsTheLockFence
mut "H13 the lock fence exempts every verb without an arm" gate_poll_lockfree_test.go \
  'return !safe && \(armed \|\| !awaitingArm\)' 'return !safe && armed' TestHealthFixAwaitingArmKeepsTheLockFence
mut "H14 GET-HEALTH gets an arm that waits on sessionMu" main.go \
  '(func concurrentSafeCmd\(name string\) bool \{\n)(.*?)(\tif name == "GET-HEALTH-FIX" \{)' \
  '\1\tif name == "GET-HEALTH" {\n\t\treturn false\n\t}\n\2\tif name == "GET-HEALTH" {\n\t\tfmt.Fprint(conn, "NONE\\n")\n\t\treturn\n\t}\n\3' TestGatePollersNeverWaitOnTheSession
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
