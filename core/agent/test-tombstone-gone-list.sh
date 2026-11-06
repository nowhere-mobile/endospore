#!/usr/bin/env bash
# test-tombstone-gone-list.sh [--mutate] -- runs the tombstone tests in app_tombstone_test.go (NWP-20261023-07): a
# tombstone is minted only from the UNINSTALL subset of the drop list (goneDropList), never for an Off (DECIDED
# 2026-09-26). --mutate re-runs them against app_tombstone.go / main.go with each guard broken in turn, restoring the
# files on exit (the pristine copies live in one scratch root, never beside the sources). Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
TOMB=app_tombstone.go; MAIN=main.go
trap 'for f in "$TOMB" "$MAIN"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestTombstone|TestGoneDropList' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "$TOMB" "$MAIN"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  for f in "$TOMB" "$MAIN"; do cp "$W/$f.orig" "$f"; done
}
mut "G1 the mint reads the whole drop list again (an Off mints)" "$MAIN" 'tombstonesToPublish\(oldM\.Gone, goneDropList\(\),' 'tombstonesToPublish(oldM.Gone, fileDropList(),'
mut "G2 goneDropList drops the drop-list intersection" "$TOMB" '\|\| !drop\[ln\] \{' '|| (false && !drop[ln]) {'
mut "G3 goneDropList falls back to the drop list when unset" "$TOMB" 'os\.Getenv\("NOWHERE_GONE_LIST"\)\n\tif p == "" \{\n\t\treturn nil' 'os.Getenv("NOWHERE_GONE_LIST")
	if p == "" {
		return fileDropList()'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
