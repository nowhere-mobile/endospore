#!/usr/bin/env bash
# test-resolver-keep-log.sh [--mutate] -- runs resolver_keep_log_test.go (NWP-20261129-29); --mutate re-runs it against
# resolver.go with the empty run's log lines broken in turn, restoring the file on exit. Each mutant must be CONVICTED
# with a --- FAIL; one that does not apply or does not compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
F=resolver.go
RUN=(go test -count=1 -run 'TestKeepLog_' .)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/orig"
trap 'cp -f "$W/orig" "$F"; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local o r
  python3 - "$F" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
  o=$("${RUN[@]}" 2>&1); r=$?
  score_mutant "$1" "$r" "$o" || fails=$((fails+1))
  cp -f "$W/orig" "$F"
}
mut "M1 the keep line is removed" 'fmt\.Fprintf\(os\.Stderr, "\[resolver\] discovery empty: keeping[^\n]*\n' ''
mut "M2 the keep line's once-per-run guard is removed" 'case dnsKeepRun == "":' 'default:'
mut "M3 the reason never reaches the fallback src" 'dropReason != "" && dropReason != "never-discovered"' 'false'
mut "M4 the back line is removed" 'fmt\.Fprintf\(os\.Stderr, "\[resolver\] discovery back after %dms empty; the kept list held[^\n]*\n' ''
mut "M5 a fall with no keep line is not remembered" 'dnsKeepRun = "silent"' 'dnsKeepRun = ""'
mut "M6 a fall after the keep line is not remembered" 'dnsKeepRun = "dropped"' 'dnsKeepRun = "printed"'
mut "M7 the run's end does not reset the state" '\n\t\tdnsKeepRun = ""\n' '
'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
