#!/usr/bin/env bash
# test-recreate-purge-time.sh [--mutate] -- runs recreate_purge_time_test.go (NWP-20261020-18); --mutate re-runs it
# against main.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED;
# one that fails to apply counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestRecreateAfterDeleteLogsTheTimedPurgeOnce' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  if "${RUN[@]}" >/dev/null 2>&1; then echo "  SURVIVED  $1"; fails=$((fails+1)); else echo "  convicted $1"; fi
  cp "$MAIN.orig" "$MAIN"
}
mut "M1 the (<ms> ms) field dropped" 'leftovers first: %s \(%d ms\)\\n",\n\t\t\tpurged, time\.Since\(purgeStart\)\.Milliseconds\(\)\)' 'leftovers first: %s\n",
			purged)
	_ = purgeStart'
mut "M2 the line printed for a name never deleted" 'if profileDeleted\(base, name, pass\) \{\n\t\tpurgeStart' 'if true {
		purgeStart'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
