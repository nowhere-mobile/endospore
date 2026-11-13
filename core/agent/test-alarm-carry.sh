#!/usr/bin/env bash
# test-alarm-carry.sh [--mutate] -- runs alarm_carry_test.go (NWP-20261129-39): ALARM-CARRY writes one login.log line for
# a valid request and answers OK; an unknown token, a missing or extra field, a trailing space or a cut request answers
# ERR-ARG and logs nothing; the verb is in concurrentSafeCmd. --mutate re-runs it against a COPY of core/agent under a
# temp root, alarm_carry.go and main.go broken in turn; the checked-out tree is never touched. Each mutant must be
# CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -run '^TestAlarmCarry' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent"
fails=0
mut() { # mut <label> <file in the copy> <python-regex pattern> <replacement>
  local res rc f
  for f in alarm_carry.go main.go; do cp -f "$f" "$W/agent/$f"; done
  python3 - "$W/agent/$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(cd "$W/agent" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
}
mut "M1 the token check loosened to any word" alarm_carry.go '\(past\|future\|bad\) now=\(none\|same\|earlier\|later\)' '(\\w+) now=(\\w+)'
mut "M2 the cut-request refusal removed" alarm_carry.go 'if err != nil \{' 'if false && err != nil {'
mut "M3 the verb dropped from the list" main.go '\t\t"ALARM-CARRY",\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
