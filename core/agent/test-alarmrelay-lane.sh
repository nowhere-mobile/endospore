#!/usr/bin/env bash
# test-alarmrelay-lane.sh [--mutate] -- runs alarmrelay_lane_test.go (NWP-20261108-02, Q183: alarmrelay rides the
# read-only lane); --mutate re-runs it against a COPY of the package with each part of the move broken in turn. Each
# mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run '^TestAlarmRelay|^TestRelayAlarmAtLock' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
mut() {
  local label="$1" f="$2" res
  cp "$f" "$W/orig.go"
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $label"
    else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "G1 laneFor no longer sends alarmrelay to the RO lane" main.go \
  'case "storagebreakdown", "sealdelta", "uiderrors", "alarmrelay":' 'case "storagebreakdown", "sealdelta", "uiderrors":'
mut "G2 relayAlarmAtLock sends the pass again" coldlock_evict.go \
  'coldLockWorker\(dest, "alarmrelay", name, "", uid,' 'coldLockWorker(dest, "alarmrelay", name, pass, uid,'
mut "G3 workerWaitCap has no alarmrelay case" main.go \
  'case "alarmrelay":\n\t\t// NWP-20261108-02: asked.*?return 3 \* time\.Second\n\t' ''
mut "G4 the teardown comment says the alarm runs inside the RW hold again" main.go \
  'The sweep runs inside the RW hold, like btpark above; the alarm rides.*?See coldlock_evict\.go\.' \
  'Both run inside the RW hold, like btpark below. See coldlock_evict.go.'
mut "G5 the dispatch comment argues only RW->Cred nesting again" main.go \
  'Credential ops \(armcred, rekey\) are laneCred and alarmrelay is laneRO.*?the RO take while RW is held\)\.' \
  'Credential ops (armcred, rekey) are laneCred and take their own slot; RW->Cred nesting cannot deadlock (TestLanesShareNoState).'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
