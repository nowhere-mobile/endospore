#!/usr/bin/env bash
# test-roamin-busy.sh [--mutate] -- runs roamin_busy_test.go (NWP-20261023-02); --mutate re-runs it against main.go with
# each of handleRoamIn's two new arms (ERR-WORKER-BUSY, ERR-TIMEOUT) broken in turn, restoring the file on exit. Each
# mutant must be CONVICTED by the named test's `--- FAIL`; one that fails to apply, or fails to compile, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run '^TestRoamInBusy_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
# conv <label> <expected failing test>: run the suite against the mutated main.go, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $2"* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$W/main.go.orig" "$MAIN"; }
mut() { # mut <label> <expected failing test> <python-regex pattern> <replacement>
  python3 - "$MAIN" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1" "$2"
}
BUSY='\t\} else if out == workerBusy \{\n.*?\n(\t\} else if out == "ERR-TIMEOUT" \{)'
TMO='(\t\} else if out == "ERR-TIMEOUT" \{\n.*?\n)\t\} else \{\n(\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] roam-in BLANK)'
mut "G1 the busy arm deleted" TestRoamInBusy_AnAbandonedLaneAnswersBusyWithNothingAsked "$BUSY" '\1'
mut "G2 the ERR-TIMEOUT arm deleted" TestRoamInBusy_ATimedOutWorkerAnswersErrTimeout \
  '\t\} else if out == "ERR-TIMEOUT" \{\n.*?\n(\t\} else \{\n\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] roam-in BLANK)' '\1'
mut "G3 the busy arm writes BLANK" TestRoamInBusy_AnAbandonedLaneAnswersBusyWithNothingAsked \
  '(nothing was attempted\\n", uid\)\n\t\t)fmt\.Fprint\(conn, workerBusy\+"\\n"\)' '\1fmt.Fprint(conn, "BLANK\\n")'
mut "G4 the timeout arm writes BLANK" TestRoamInBusy_ATimedOutWorkerAnswersErrTimeout \
  'fmt\.Fprint\(conn, "ERR-TIMEOUT\\n"\)' 'fmt.Fprint(conn, "BLANK\\n")'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
