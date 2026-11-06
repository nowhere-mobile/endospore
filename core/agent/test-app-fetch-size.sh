#!/usr/bin/env bash
# test-app-fetch-size.sh [--mutate] -- runs app_fetch_size_test.go and TestConcurrentSafeCmd (NWP-20261114-16, dn-1023
# #5): APP-FETCH-SIZE answers the size of an on-demand fetch before it starts, from the session's own name#apps head,
# over exactly the rels restoreAppCode fetches; it answers ERR for a damaged head and runs outside sessionMu. --mutate
# re-runs it against a COPY of the package with each guard broken in turn; the tree is never touched. Each mutant must
# be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestAppFetchBytes|TestIsPkgApkRelMatchesRestore|TestAppFetchSizeVerb|TestConcurrentSafeCmd' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res mrc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - "$file" "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
mut "M1 appFetchBytes counts nested rels" app_code.go \
  "$(one "r'(\t\tfor rel, d := range m\.Deferred \{\n\t\t\tif )isPkgApkRel\(rel, pkg\)( \{\n\t\t\t\tbytes \+= d\.Size)'" "lambda m: m.group(1) + 'strings.HasPrefix(rel, pkg+\"/\")' + m.group(2)")"
mut "M2 appFetchBytes double-counts a duplicate package" app_code.go \
  "$(one "r'if !validPkgName\(pkg\) \|\| seen\[pkg\] \{'" "'if !validPkgName(pkg) {'")"
mut "M3 appFetchBytes counts an invalid package" app_code.go \
  "$(one "r'if !validPkgName\(pkg\) \|\| seen\[pkg\] \{'" "'if seen[pkg] {'")"
mut "M4 the verb reads the CE scope (name), not name#apps" app_fetch_size.go \
  "$(one "r'resolveKeySession\(\"s3\", name\+\"#apps\", '" "'resolveKeySession(\"s3\", name, '")"
mut "M5 the verb answers OK 0 0 on a failed resolve" app_fetch_size.go \
  "$(one "r'(\}\) != nil \|\| !ok \{\n\t\tfmt\.Fprint\(conn, )\"ERR\\\\n\"'" "lambda m: m.group(1) + '\"OK 0 0\\\\n\"'")"
mut "M6 the request bound is 17, not 16" app_fetch_size.go \
  "$(one "r'const appFetchSizeMaxPkgs = 16'" "'const appFetchSizeMaxPkgs = 17'")"
mut "M7 APP-FETCH-SIZE removed from concurrentSafeCmd" main.go \
  "$(one "r'\n\t\t\"APP-FETCH-SIZE\",\n'" "'\n'")"
mut "M8 a damaged manifest's unseal panic is not recovered" app_fetch_size.go \
  "$(one "r'if recovered\(func\(\) \{ pt = unseal\(key, mb\) \}\) != nil \{'" "'if pt = unseal(key, mb); pt == nil {'")"
mut "M9 a damaged head's resolve panic is not recovered" app_fetch_size.go \
  "$(one "r'if recovered\(func\(\) \{ key, mb, ok = (resolveKeySession\([^\n]*\)) \}\) != nil \|\| !ok \{'" "lambda m: 'if key, mb, ok = ' + m.group(1) + '; !ok {'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
