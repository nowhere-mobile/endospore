#!/usr/bin/env bash
# test-delete-purge-wiring.sh [--mutate] -- runs delete_purge_wiring_test.go (NWP-20261029-16): deleteForSession
# purges the profile's SIM bindings and sealed inbox on "deleted" and "gone", with the TYPED credentials, and on no
# other verdict. --mutate re-runs it against main.go with the wiring broken six ways, restoring the file on exit.
# Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'DeletePurgeWiring|DeleteForSession|DeleteDropsTheProfile|NoMatchWritesNothing|EmptyRefUnbinds|TombstoneIsRefused' .)
W=$(mktemp -d) || exit 2
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/main.go.orig"
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local res
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "P1 the purge dropped from the deleted arm" '(\tcase "deleted":\n)\t\tpurgeLocalProfileState\(name, pass\)\n' '\1'
mut "P2 the purge dropped from the gone arm" '(\tcase "gone":\n)\t\tpurgeLocalProfileState\(name, pass\)[^\n]*\n' '\1'
mut "P3 the purge also on the unverified arm" '(\tcase "unverified":\n)' '\1\t\tpurgeLocalProfileState(name, pass)\n'
mut "P4 the purge before the switch, for every verdict" '(\tswitch deleteProfileSE\(base, name, pass, se\) \{)' '\tpurgeLocalProfileState(name, pass)\n\1'
mut "P5 clearTelInbox dropped from purgeLocalProfileState" '\tclearTelInbox\(ref\)\n\}' '}'
mut "P6 the purge keyed by the session login creds" '(\tcase "deleted":\n\t\t)purgeLocalProfileState\(name, pass\)(.*?\tcase "gone":\n\t\t)purgeLocalProfileState\(name, pass\)' '\1purgeLocalProfileState(loginName, loginPass)\2purgeLocalProfileState(loginName, loginPass)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
