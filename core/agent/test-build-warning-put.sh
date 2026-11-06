#!/usr/bin/env bash
# test-build-warning-put.sh [--mutate] -- runs build_warning_put_test.go (NWP-20261113-30); --mutate re-runs it
# against build_warning_put.go with each guard broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
SRC=build_warning_put.go
trap '[ -f "$W/orig" ] && cp -f "$W/orig" "$SRC"; rm -rf "$W"' EXIT
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestBuildWarningPut|TestBuildWarningCheck' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/orig"
cat >"$W/mut.py" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local res
  python3 "$W/mut.py" "$SRC" "$2" "$3" || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp -f "$W/orig" "$SRC"
}
mut "P1 the strict seq comparison relaxed (an equal seq published)" \
  'if w\.Seq <= p\.Seq \{' 'if w.Seq < p.Seq {'
mut "P2 the published-envelope read's error ignored (published blind)" \
  'if err != nil \{(\s*)return nil, "", fmt\.Errorf\("the published warning could not be read' \
  'if _ = err; false {
		return nil, "", fmt.Errorf("the published warning could not be read'
mut "P3 a published blob that fails verification treated as none" \
  'if perr != nil \{(\s*)return nil, "", fmt\.Errorf\("the published warning verifies neither' \
  'if perr != nil {
			p = &buildWarning{}
		}
		if false {
			return nil, "", fmt.Errorf("the published warning verifies neither'
mut "P4 the check's verify removed (any file published)" \
  'verifyBuildWarning\(buildWarningKey, env, now, 0\)' \
  '&buildWarning{Schema: 1, Seq: 1 << 40, Versions: []string{"0.5.45"}}, error(nil)'
mut "P5 the expired-published fallback removed" \
  'p, perr = verifyBuildWarning\(buildWarningKey, pub, \*wire\.Issued, 0\)' '_ = wire'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
