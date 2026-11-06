#!/usr/bin/env bash
# test-catalog-rollback.sh [--mutate] -- runs the TestCatalogRollback_* tests (NWP-20261028-16); --mutate re-runs them
# against catalog.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
CAT=catalog.go
trap '[ -f "$CAT.orig" ] && mv -f "$CAT.orig" "$CAT"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestCatalogRollback_|TestLoadCatalogBytes|TestRefreshCatalog|TestSeedCatalog' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -15
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp "$CAT" "$CAT.orig"
fails=0
mut() { # mut <label> <regex pattern> <repl>
  python3 - "$CAT" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  cp "$CAT.orig" "$CAT"
}
mut "C1 read guard removed" 'if indexGeneratedOf\(b\) >= indexGeneratedOf\(baked\) \{' 'if true {'
mut "C2 >= became >" 'if indexGeneratedOf\(b\) >= indexGeneratedOf\(baked\) \{' 'if indexGeneratedOf(b) > indexGeneratedOf(baked) {'
mut "C3 refresh no-op removed" 'if c\.Generated <= indexGeneratedOf\(loadCatalogBytes\(\)\) \{' 'if false {'
mut "C4 generated sanity removed" 'if c\.Generated <= 0 \|\| c\.Generated > now\+86400 \{' 'if false && (c.Generated <= 0 || c.Generated > now+86400) {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
