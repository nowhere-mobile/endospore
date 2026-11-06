#!/usr/bin/env bash
# test-index-verbs-exec.sh [--mutate] -- executes SEARCH-APPS, REFRESH-INDEX and REFRESH-CATALOG through their handlers
# (index_verbs_exec_test.go, TestSearchSanitize; NWP-20261127-17); --mutate re-runs them against index.go and catalog.go
# with each fix broken in turn, restoring both files on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'for f in index.go catalog.go; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestSearch|TestIndexVerbs|TestRefreshIndex|TestCatalogURL|TestRefreshCatalog|TestEveryGoroutineGoesThroughGoSafe' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp index.go "$W/index.go.orig"
cp catalog.go "$W/catalog.go.orig"
fails=0
# mut <file> <label> <python expression over s; r(s, old, new) replaces old once and gives None unless old occurs once>
mut() {
  local f=$1 label=$2 res
  python3 - "$f" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$f.orig" "$f"; return; }
import sys
p, expr = sys.argv[1:3]
def r(s, old, new):
    return None if s is None or s.count(old) != 1 else s.replace(old, new, 1)
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$f.orig" "$f"
}
mut index.go "M1 the query cut back to a byte cut" \
  "r(r(s, '\t\tcut := searchMaxQuery\n\t\tfor cut > 0 && !utf8.RuneStart(query[cut]) {\n\t\t\tcut--\n\t\t}\n\t\tquery = query[:cut]\n', '\t\tquery = query[:searchMaxQuery]\n'), '\t\"unicode/utf8\"\n', '')"
# M2 drops the [] at both layers: searchIndex's zero-length make is not nil, so the handler's guard alone is
# unreachable today and a mutant that drops only the guard is equivalent. The test pins the reply's "entries":[].
mut index.go "M2 the [] for a no-match query dropped" \
  "r(r(s, '\tif rep.Entries == nil && strings.TrimSpace(query) != \"\" {\n\t\trep.Entries = []catalogEntry{}\n\t}\n', ''), '\tout := make([]catalogEntry, len(hits))\n', '\tvar out []catalogEntry\n\tif len(hits) > 0 {\n\t\tout = make([]catalogEntry, len(hits))\n\t}\n')"
mut index.go "M3 the control-character strip dropped" \
  "r(s, '\tquery = strings.Map(func(r rune) rune {\n\t\tif r < 0x20 || r == 0x7f {\n\t\t\treturn -1\n\t\t}\n\t\treturn r\n\t}, query)\n', '')"
mut index.go "M4 handleRefreshIndex back to substring matching" \
  "r(s, '\tif errors.Is(err, errRefreshOff) {\n', '\tif m := err.Error(); strings.Contains(m, \"disabled\") || strings.Contains(m, \"no source\") {\n')"
mut catalog.go "M5 handleRefreshCatalog back to substring matching" \
  "r(s, '\tif errors.Is(err, errRefreshOff) {\n', '\tif m := err.Error(); strings.Contains(m, \"disabled\") || strings.Contains(m, \"no source\") {\n')"
mut index.go "M6 refreshIndex's no-source return no longer wraps errRefreshOff" \
  "r(s, 'no source (set INDEX_URL or GATEWAY_URL): %w\", errRefreshOff)', 'not configured (set INDEX_URL or GATEWAY_URL)\")')"
mut catalog.go "M7 refreshCatalog's disabled return no longer wraps errRefreshOff" \
  "r(s, 'catalog refresh disabled: no signing key baked: %w\", errRefreshOff)', 'catalog refresh not configured: no signing key baked\")')"
mut index.go "M8 handleRefreshIndex's success reply OK turned to ERR" \
  "r(s, '\terr := refreshIndex()\n\tif err == nil {\n\t\tfmt.Fprint(conn, \"OK', '\terr := refreshIndex()\n\tif err == nil {\n\t\tfmt.Fprint(conn, \"ERR')"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
