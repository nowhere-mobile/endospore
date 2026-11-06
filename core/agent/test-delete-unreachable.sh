#!/usr/bin/env bash
# test-delete-unreachable.sh [--mutate] -- runs delete_unreachable_test.go (NWP-20261028-01): DELETE against a store
# that cannot be reached answers ERR-STORE and keeps the session. --mutate re-runs the focused tests against a
# pristine copy of main.go with each rule broken in turn, restoring the file on exit. Each mutant must be CONVICTED by
# a real `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'DeleteUnreachable|MailboxRules|DeleteDeadline' .)
W=$(mktemp -d) || exit 2
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/main.go.orig"
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local res
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$W/main.go.orig" "$MAIN"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else
    if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- did not compile"; else echo "  SURVIVED  $1"; fi
    fails=$((fails+1))
  fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "D1 the recover removed" '(verdict := func\(\) \(v string\) \{\n)\t\tdefer func\(\) \{.*?\n\t\t\}\(\)\n(\t\treturn deleteForSessionFn)' '\1\2'
mut "D2 every recovered panic mapped to ERR-STORE" 'ok && errors\.Is\(err, errStoreUnreachable\)' 'ok && err != nil'
mut "D3 the unreachable arm queues the reap" '(\tcase "unreachable":\n)' '\1\t\tpendingReapMu.Lock()\n\t\tpendingSwitchUID, pendingReapUID = uid, uid\n\t\tpendingReapMu.Unlock()\n'
mut "D4 the unreachable arm removes .roamsession" '(\tcase "unreachable":\n)' '\1\t\tos.Remove(filepath.Join(dest, ".roamsession"))\n'
mut "D5 the unreachable arm replies NOTFOUND" '(the store could not be reached[^\n]*\n\t\tfmt\.Fprint\(conn, ")ERR-STORE' '\1NOTFOUND'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
