#!/usr/bin/env bash
# test-coldlock-rekey-result.sh [--mutate] -- runs coldlock_rekey_result_test.go (NWP-20261017-13); --mutate re-runs it
# against main.go with the forward-rekey handling broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED (a failing test); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestColdLockForwardRekey' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  cp "$MAIN.orig" "$MAIN"
}
# M1 (the forward reply ignored again) retired by NWP-20261031-06: a refused forward rekey is now revoked above the wait, so Check B's fwdNeverMoved skip is defence in depth that no test can reach; coldlock_armfail_test.go convicts the earlier branch (test-coldlock-armfail.sh A1).
mut "M2 skip also after a rekey that landed" 'fwdNeverMoved := fwdRekeyNeverMoved\(fwdRekey\)' 'fwdNeverMoved := fwdRekey == "OK" || fwdRekeyNeverMoved(fwdRekey)'
mut "M3 the unwind run but its failure ignored" 'out != "OK" \{\n(\t+fmt\.Fprintf\(os\.Stderr, "\[logind\] cold-lock abort DECLINED)' 'out == "" {\n\1'
mut "M4 skip on any non-OK reply" 'fwdNeverMoved := [^\n]*\n' 'fwdNeverMoved := fwdRekey != "OK" && fwdRekey != ""\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
