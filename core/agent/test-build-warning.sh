#!/usr/bin/env bash
# test-build-warning.sh [--mutate] -- runs build_warning_test.go (NWP-20261109-24); --mutate re-runs it against
# build_warning.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
SRC=build_warning.go
trap '[ -f "$W/orig" ] && cp -f "$W/orig" "$SRC"; rm -rf "$W"' EXIT
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestBuildWarning' .)

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
mut "N1 domain prefix dropped from the verify" 'msg = append\(append\(msg, buildWarningDomain\.\.\.\), body\.\.\.\)' 'msg = append(msg, body...)'
mut "N2 seq > floor relaxed to >=" 'if seq <= floor \{' 'if seq < floor {'
mut "N3 staleness check removed" 'if issued < now-maxIndexStaleness \{' 'if false {'
mut "N4 expiry check removed" 'if expires <= now \{' 'if false {'
mut "N5 zero fields defaulted, not refused" 'if p == nil \|\| \*p <= 0 \{' 'if p == nil { return 0, nil }; if false {'
mut "N6 affects true for any version" 'if v == version \{' 'if v == version || true {'
mut "N7 duplicate check removed" 'if seen\[v\] \{' 'if false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
