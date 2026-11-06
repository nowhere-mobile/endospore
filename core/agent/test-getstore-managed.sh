#!/usr/bin/env bash
# test-getstore-managed.sh [--mutate] -- runs getstore_managed_test.go and the SET-STORE-MANAGED verb tests
# (NWP-20261113-21): GET-STORE ends with managed=yes on a managed (cap-mode) device and managed=no with an S3 config or
# no store, its first five lines unchanged and in order, and no line carries a key or the gateway URL. --mutate re-runs
# it against a COPY of core/agent under a temp root, handleGetStore in main.go broken in turn; the checked-out tree is
# never touched. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a
# failure. Mutants: G1 handleGetStore never prints managed=yes; G2 it prints managed= before keyset=; G3 it reads
# storeConfigured() instead of capMode().
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -run '^TestSetStoreManaged|^TestGetStore' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent"
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>  (applied to the copy's main.go)
  local res rc
  cp -f main.go "$W/agent/main.go"
  python3 - "$W/agent/main.go" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(cd "$W/agent" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
}
mut "G1 handleGetStore never prints managed=yes" '(func handleGetStore\(.*?)managed = "yes"' '\1managed = "no"'
mut "G2 handleGetStore prints managed= before keyset=" '(func handleGetStore\(.*?)keyset=%s\\nmanaged=%s\\n(.*?)keyset, managed\)' '\1managed=%s\\nkeyset=%s\\n\2managed, keyset)'
mut "G3 handleGetStore reads storeConfigured() for managed=" '(func handleGetStore\(.*?)if capMode\(\) \{(\n\t+managed = "yes")' '\1if storeConfigured() {\2'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
