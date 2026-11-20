#!/usr/bin/env bash
# test-ota-worker-live.sh [--mutate] -- runs the OTA worker liveness cases (ota_worker_live_test.go; NWP-20261206-12)
# with the older OTA-STATUS and sign-in refusal cases; --mutate re-runs them against main.go and report_issue.go with
# the code broken in turn, restoring both files on exit. Each mutant must be CONVICTED by a real `--- FAIL` of the test
# it names; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'for f in main.go report_issue.go; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestOtaWorker|TestOtaResState|TestOtaApplyBusy|TestOtaInstallMarker|TestOtaSigninRefusal' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp report_issue.go "$W/report_issue.go.orig"
fails=0
mut() { # mut <label> <file> <test that must fail> <python expression over s: the mutated text, or None when it does not apply>
  local label=$1 f=$2 want=$3 res mrc nl=$'\n'
  if ! python3 - "$f" "$4" <<'PY'
import sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$f.orig" "$f"; return
  fi
  res=$("${RUN[@]}" 2>&1); mrc=$?
  cp -f "$W/$f.orig" "$f"
  if ! score_mutant "$label" "$mrc" "$res"; then fails=$((fails+1)); return; fi
  if [[ "$nl$res" != *"$nl--- FAIL: $want "* ]]; then
    echo "    but $want did not fail -- the named assertion does not convict it"; fails=$((fails+1))
  fi
}
one() { # one <old> <new>: the python expression replacing exactly one occurrence of old
  printf 's.replace(%s, %s, 1) if s.count(%s) == 1 else None' "$1" "$2" "$1"
}
mut "W1 an empty svc read is dead again (main's != \"running\")" main.go TestOtaWorkerLiveEmptyReadFresh \
  "$(one "'\tif s != \"\" {\n\t\treturn true'" "'\tif s != \"running\" {\n\t\treturn true'")"
mut "W2 the freshness window ignores ota.prog" main.go TestOtaWorkerLiveEmptyReadFresh \
  "$(one "'[]string{\"ota.res\", \"ota.prog\"}'" "'[]string{\"ota.res\"}'")"
mut "W3 a stale empty read stays live (window check removed)" main.go TestOtaWorkerLiveEmptyReadStale \
  "$(one "'\treturn true\n}\n\n// otaLiveWindow is'" "'\treturn false\n}\n\n// otaLiveWindow is'")"
mut "W4 stopped read as live" main.go TestOtaWorkerDeadStopped \
  "$(one "'return s == \"running\" || s == \"stopping\" || s == \"restarting\"\n'" "'return s == \"running\" || s == \"stopping\" || s == \"restarting\" || s == \"stopped\"\n'")"
mut "W5 otaResState's running override removed" main.go TestOtaResStateAbsentWhileOtadRuns \
  "$(one "'return \"DOWNLOADING\"\n\t\t}'" "'return \"\"\n\t\t}'")"
mut "W6 handleOtaApply's running BUSY removed" main.go TestOtaApplyBusyWhileOtadRuns \
  "$(one "'if s, err := otadSvcState(); err == nil && otadSvcLive(s) {'" "'if s, err := otadSvcState(); false && err == nil && otadSvcLive(s) {'")"
mut "W7 the marker keys set only when absent (the chooser's key wins)" report_issue.go TestOtaInstallMarker \
  "$(one "'for k, v := range otaInstallMarker(dest) {\n\t\trep.Status[k] = v\n\t}'" "'for k, v := range otaInstallMarker(dest) {\n\t\tif _, ok := rep.Status[k]; !ok {\n\t\t\trep.Status[k] = v\n\t\t}\n\t}'")"
mut "W8 running read as dead (the running leg)" main.go TestOtaWorkerDeadStopped \
  "$(one "'return s == \"running\" || s == \"stopping\"'" "'return s == \"stopping\"'")"
mut "W9 UPTODATE/NONE fall to the running override (the UPTODATE leg)" main.go TestOtaResStateAbsentWhileOtadRuns \
  "$(one "'\tcase \"UPTODATE\", \"NONE\": // otad writes these as it exits -> let the live check answer AVAIL/NONE\n\t\treturn \"\"\n'" "''")"
mut "W10 the override fires on any service read (the stopped leg)" main.go TestOtaResStateAbsentWhileOtadRuns \
  "$(one "'err == nil && s == \"running\" {'" "'err == nil && s != \"none\" {'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
