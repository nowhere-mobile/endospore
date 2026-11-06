#!/usr/bin/env bash
# test-catalog-url.sh [--mutate] -- runs the CATALOG_URL-only refresh cases (catalog_url_test.go; NWP-20261104-13);
# --mutate re-runs them against catalog.go with each change broken in turn, restoring the file on exit. Each mutant must
# be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=catalog.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestCatalogURL_|TestRefreshCatalog' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$F.orig" "$F"
}
mut "C1 the GATEWAY_URL fallback restored" \
  "s.replace('\treturn strings.TrimRight(os.Getenv(\"CATALOG_URL\"), \"/\")\n', '\tif u := strings.TrimRight(os.Getenv(\"CATALOG_URL\"), \"/\"); u != \"\" {\n\t\treturn u\n\t}\n\tif gw := strings.TrimRight(os.Getenv(\"GATEWAY_URL\"), \"/\"); gw != \"\" {\n\t\treturn gw + \"/catalog.json\"\n\t}\n\treturn \"\"\n', 1) if s.count('\treturn strings.TrimRight(os.Getenv(\"CATALOG_URL\"), \"/\")\n') == 1 else None"
mut "C2 the no-source text loses \"no source\"" \
  "s.replace('no source (CATALOG_URL unset)', 'unconfigured (CATALOG_URL unset)', 1) if s.count('no source (CATALOG_URL unset)') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
