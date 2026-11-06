#!/usr/bin/env bash
# test-tel-handoff-readfail.sh [--mutate] -- runs tel_handoff_readfail_test.go (NWP-20261017-25); --mutate re-runs it
# against main.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED (a
# `--- FAIL` line); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestTelHandoff' .)

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
mut "M1 FAILED line removed" 'if e, ok := r\.\(error\); ok && errors\.Is\(e, errStoreUnreachable\) \{.*?\n\t\treturn\n\t\}\n' ''
mut "M2 error printed raw, not through logSafeStoreErr" 'logSafeStoreErr\("telephony hand-off", e\)' 'e.Error()'
mut "M3 recover rethrows" 'func telHandoffPanic\(kind, name string, r any\) \{\n\tif r == nil \{\n\t\treturn\n\t\}' 'func telHandoffPanic(kind, name string, r any) {
	if r == nil {
		return
	}
	defer panic(r)'
mut "M4 generic line prints the panic value" 'unexpected failure \(details withheld\) -- "\+\n\t\t"the sealed items stay for the next resume or sign-in\\n", kind, name\)' 'unexpected failure (details withheld) -- "+
		"the sealed items stay for the next resume or sign-in %v\\n", kind, name, r)'
mut "M5 name printed unquoted" '"\[logind\] %s %q -> telephony hand-off skipped: store read FAILED' '"[logind] %s %s -> telephony hand-off skipped: store read FAILED'
mut "M6 resume hand-off back to a bare recover" 'defer func\(\) \{ telHandoffPanic\("resume", name, recover\(\)\) \}\(\)' 'defer func() { recover() }()'
mut "M7 roam-in hand-off back to a bare recover" 'defer func\(\) \{ telHandoffPanic\("roam-in", name, recover\(\)\) \}\(\)' 'defer func() { recover() }()'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
