#!/usr/bin/env bash
# test-avc-device-scope.sh [--mutate] -- runs avc_device_scope_test.go (NWP-20261107-05, dn-1105 #1); --mutate re-runs it
# against a PACKAGE COPY per mutant with one rule of deviceScopeDenials broken in turn. Each mutant must be CONVICTED
# (a `--- FAIL`); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestDeviceScopeDenials' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local d res
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R ./*.go go.mod go.sum blindrsa testdata third_party "$d"/
  if ! python3 - "$d/report_issue.go" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; fi
  res=$(cd "$d" && "${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  rm -rf "$d"
}
mut "V1 anywhere-in-the-line Contains rule" 'm := avcScontextRe\.FindStringSubmatch\(ln\)\n\t\tif m == nil \|\| !deviceScopeDomains\[m\[1\]\] \{' 'if !(strings.Contains(ln, "update_engine") || strings.Contains(ln, "nowhere_") || strings.Contains(ln, "otad")) {'
mut "V2 app= strip removed" 'kept = append\(kept, avcAppFieldRe\.ReplaceAllString\(ln, ""\)\)' 'kept = append(kept, ln)'
mut "V3 su left off the list" '"endospore_mediad": true, "su": true,' '"endospore_mediad": true,'
mut "V4 prefix match instead of exact" '!deviceScopeDomains\[m\[1\]\]' '!func(d string) bool { for k := range deviceScopeDomains { if strings.HasPrefix(d, k) { return true } }; return false }(m[1])'
mut "V5 the tcontext read instead of the scontext" 'bscontext=u:r:' 'btcontext=u:r:'
mut "V6 the session scope filtered too" 'if deviceScope \{\n\t\t// dn-1105 #1' 'if true {
		// dn-1105 #1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
