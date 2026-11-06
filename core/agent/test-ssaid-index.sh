#!/usr/bin/env bash
# test-ssaid-index.sh [--mutate] -- runs ssaid_index_test.go and ssaid_userkey_test.go (NWP-20261122-12): the SSAID
# userkey is recorded in the vault's key-sealed scope index (!ssaid) at the first bare seal, carried through every
# rotation and recovery, and seeded by SEED-SSAID from there, with the same read made for a blank. --mutate re-runs
# them against a COPY of core/agent under a temp root, main.go, scope_index.go and scope_repoint.go broken in turn;
# the checked-out tree is never touched. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or
# fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -run '^TestSsaid|^TestHandleSeedSsaidUsesHelper$' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent"
fails=0
mut() { # mut <label> <file in the copy> <python-regex pattern> <replacement>
  local res rc f
  for f in main.go scope_index.go scope_repoint.go; do cp -f "$f" "$W/agent/$f"; done
  python3 - "$W/agent/$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(cd "$W/agent" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
}
mut "M1 the pushProfile backfill removed" main.go 'if ssaidOf\(idx\) == "" \{(\n\t+idx\[scopeSsaidKey\] = ssaidRec\(ssaidUserKey\(deriveKey\(profile, pass\)\)\))' 'if false {\1'
mut "M2 the bare seal overwrites instead of minting if absent" main.go 'if ssaidOf\(idx\) == "" \{(\n\t+idx\[scopeSsaidKey\] = ssaidRec\(ssaidUserKey\(deriveKey\(profile, pass\)\)\))' 'if true {\1'
mut "M3 seedSsaidKey ignores the record" main.go '(case r := <-ch:\n\t\tif) r != "" \{' '\1 false {'
mut "M4 the rotation does not record" main.go 'if ssaidOf\(nidx\) == "" \{' 'if false {'
mut "M5 the repointScopes carry removed" scope_repoint.go 'if uk := ssaidOf\(idx\); uk != "" \{' 'if uk := ssaidOf(idx); false && uk != "" {'
mut "M6 !ssaid missing from isScopeSuffix" scope_index.go ' \&\&\n\t\tk != scopeSsaidKey\n' '\n'
mut "M7 the blank path skips the read" main.go '(def := ssaidUserKey\(deriveKey\(nm, pw\)\)\n)' '\1\tif dk, _ := resolveDKVault(seedSsaidStore, nm, pw, nil); dk == nil {\n\t\treturn def\n\t}\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
