#!/usr/bin/env bash
# test-report-conf-keys.sh [--mutate] -- runs report_conf_keys_test.go (NWP-20261104-18, Q152): an issue report names its
# device's conf keys and never a value. --mutate re-runs it against report_issue.go with each rule broken in turn,
# restoring it on exit. Each mutant must be CONVICTED (a `--- FAIL`); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export GOTMPDIR="$W"
RUN=(go test -count=1 -run 'ConfKey' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp report_issue.go "$W/report_issue.go.orig"
trap 'cp -f "$W/report_issue.go.orig" report_issue.go; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local res
  python3 - report_issue.go "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$W/report_issue.go.orig" report_issue.go; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/report_issue.go.orig" report_issue.go
}
mut "R1 the whole line kept (values leak)" 'seen\[m\[1\]\] = true' 'seen[ln] = true'
mut "R2 comment lines admitted" '\^\(\[A-Za-z_\]\[A-Za-z0-9_\]\*\)=' '^#?[ ]*([A-Za-z_][A-Za-z0-9_]*)='
mut "R3 absent and unreadable both none" 'return "unreadable"' 'return "none"'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
