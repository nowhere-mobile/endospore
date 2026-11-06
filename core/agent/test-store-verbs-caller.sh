#!/usr/bin/env bash
# test-store-verbs-caller.sh [--mutate] -- runs store_verbs_caller_test.go (NWP-20261021-18); --mutate re-runs it with
# the store-config caller gate broken in turn (owner_key.go / main.go), restoring both files on exit. Each mutant must
# be CONVICTED (a `--- FAIL`); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
export TMPDIR="$W"
RUN=(go test -count=1 -run 'TestStoreConfigCmd|TestStoreVerb' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -12
if [ $rc -ne 0 ]; then echo FAILED; rm -rf "$W"; exit 1; fi
if [ "${1:-}" != --mutate ]; then rm -rf "$W"; exit 0; fi

cp owner_key.go "$W/owner_key.go.orig"
cp main.go "$W/main.go.orig"
restore() { cp "$W/owner_key.go.orig" owner_key.go; cp "$W/main.go.orig" main.go; }
trap 'restore; rm -rf "$W"' EXIT
fails=0
edit() { # edit <file> <python-regex> <replacement>
  python3 - "$1" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
}
mut() { # mut <label> <file> <regex> <replacement> [<file2> <regex2> <replacement2>]
  local label=$1 res
  edit "$2" "$3" "$4" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
  if [ -n "${5:-}" ]; then
    edit "$5" "$6" "$7" || { echo "  INERT     $label -- the second mutation did not apply"; fails=$((fails+1)); restore; return; }
  fi
  res=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $label"; else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  restore
}
mut "M1 TEST-STORE dropped from storeConfigCmd" owner_key.go '"SET-STORE", "SET-STORE-MANAGED", "TEST-STORE"' '"SET-STORE", "SET-STORE-MANAGED"'
mut "M2 root refused" owner_key.go 'uid == 0 \|\| ownerCallerOK\(uid\)' 'ownerCallerOK(uid)'
mut "M3 check moved after the TryLock/Lock block" main.go '\tif refusedStoreConfigCaller\(conn, name\) \{\n\t\treturn\n\t\}\n' '' \
  main.go '\t\tif !sessionMu\.TryLock\(\) \{' '	if refusedStoreConfigCaller(conn, name) {
		return
	}
		if !sessionMu.TryLock() {'
mut "M4 a roamed caller admitted (uid normalised before the check)" owner_key.go 'uid == 0 \|\| ownerCallerOK\(uid\)' 'uid == 0 || ownerCallerOK(uid%100000)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
