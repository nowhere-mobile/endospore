#!/usr/bin/env bash
# test-fetch-icon-guard.sh [--mutate] -- runs catalog_icon_test.go (NWP-20261019-28); --mutate re-runs it against
# catalog.go with each FETCH-ICON guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED
# (a `--- FAIL`); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
SRC=catalog.go
RUN=(go test -count=1 -run 'TestFetchIcon' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -8
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$SRC.orig"
trap 'mv -f "$SRC.orig" "$SRC"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  python3 - "$SRC" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$SRC.orig" "$SRC"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$SRC.orig" "$SRC"
}
mut "M1 catalogHasIconURL always true" 'func catalogHasIconURL\(url string\) bool \{' 'func catalogHasIconURL(url string) bool {
	if true {
		return true
	}'
mut "M2 allow-list by prefix, not equality" 'c\.Entries\[i\]\.IconRef == url' 'strings.HasPrefix(url, c.Entries[i].IconRef)'
mut "M3 scheme test reduced to a bare http prefix" '!strings\.HasPrefix\(arg, "http://"\) && !strings\.HasPrefix\(arg, "https://"\)' '!strings.HasPrefix(arg, "http")'
mut "M4 read back to the bare cap" 'io\.LimitReader\(resp\.Body, iconCap\+1\)' 'io.LimitReader(resp.Body, iconCap)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
