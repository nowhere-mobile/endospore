#!/usr/bin/env bash
# test-seal-delta-se.sh [--mutate] -- runs the SEAL-DELTA secure-element tests (NWP-20261026-09): a tied profile's #apps
# head and saved-file index open in the login daemon with the session's secret. --mutate re-runs them against
# seal_delta.go with the secret dropped (or the cache's profile guard removed) in turn, restoring the file on exit.
# Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=seal_delta.go
RUN=(go test -count=1 -run 'SealDelta|StoredApps|ResolveKeySession|ListMediaApps' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$SRC" "$W/seal_delta.go.orig"
trap 'cp -f "$W/seal_delta.go.orig" "$SRC" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/seal_delta.go.orig" "$SRC"; }
# conv <label>: run the suite against the mutated file, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: Test'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$SRC" "$2" "$3" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
mut "E1 the apps refresh passes a nil secret" 'name\+"#apps", pass, se\)' 'name+"#apps", pass, nil)'
mut "E2 handleSealDelta passes a nil secret" 'storedAppsCached\(name, pass, se\)\n' 'storedAppsCached(name, pass, nil)
		_ = se
'
mut "E3 the walk refresh passes a nil secret" '(se := seFromSession\(dest\)\n)(\tsince := .*?)pass, se\); ok' '\1\t_ = se\n\2pass, nil); ok'
mut "E4 the cache serves another profile's rows" '\tif c\.name != name \{\n\t\tapps, known = nil, false[^\n]*\n\t\}\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
