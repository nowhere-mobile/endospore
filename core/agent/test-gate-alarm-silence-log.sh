#!/usr/bin/env bash
# test-gate-alarm-silence-log.sh [--mutate] -- runs gate_alarm_silence_log_test.go (NWP-20261028-12); --mutate re-runs it
# against main.go / gate_log.go with each line of the SILENCE-GATE-ALARM trace broken in turn, restoring the files on exit.
# Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go; GL=gate_log.go
RUN=(go test -count=1 -run 'TestGateAlarmSilenceLog_' -v .)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"; for f in "$MAIN" "$GL"; do [ ! -f "$f.orig" ] || mv -f "$f.orig" "$f"; done' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -15
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

for f in "$MAIN" "$GL"; do cp "$f" "$f.orig"; done
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local res
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  for f in "$MAIN" "$GL"; do cp "$f.orig" "$f"; done
}
mut "S1 silence-live written as silence-ok" "$MAIN" 'case "ERR-LIVE":\n\t\t\tgateLog\("silence-live"' 'case "ERR-LIVE":
			gateLog("silence-ok"'
mut "S2 stale arm line removed" "$MAIN" '\t\t\tgateLog\("silence-stale", "", 0\)\n' ''
mut "S3 cold-lock arm line removed" "$MAIN" '\t\t\t\t\tgateLog\("silence-coldlock", "", 0\)\n' ''
mut "S4 silence-stale missing from gateLogVerbs" "$GL" '\t"silence-stale": true,\n' ''
mut "S5 the uid written as the in value of silence-ok" "$MAIN" 'case "OK":\n\t\t\tgateLog\("silence-ok", "", 0\)' 'case "OK":
			gateLog("silence-ok", "in", uid)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
