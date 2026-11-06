#!/usr/bin/env bash
# test-delete-release-se.sh [--mutate] -- runs delete_release_se_test.go (NWP-20261114-17, backlog §D "A delete leaves
# the profile's encrypted blobs in the store until their leases lapse and the plan's hold ends": a tied or key-only
# profile's delete opens its vault and releases the blobs); --mutate re-runs it against a COPY of the package with
# main.go broken in turn (the work tree is never edited). Each mutant must be CONVICTED by a `--- FAIL`; one that
# fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=$PWD
PAT='TestDeleteReleaseSE'

out=$(go test -count=1 -run "$PAT" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <python regex> <replacement>: exactly one match in main.go of a fresh copy of the package, or INERT.
mut() {
  local label="$1" pat="$2" rep="$3" d res rc
  d=$(mktemp -d -p "$W") || exit 2
  cp -r "$SRC/." "$d/"
  if ! python3 - "$d/main.go" "$pat" "$rep" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; fi
  res=$(cd "$d" && go test -count=1 -run "$PAT" . 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  rm -rf "$d"
}

mut "S1 handleDelete passes no chip secret" 'deleteSessionSE\(name, pass, ln, lp, readRoamSessionSE\(dest\)\)' 'nil'
mut "S2 handleDelete does not adopt the cached key hmac" '(func handleDelete\(.*?)\tloadFido2HmacEnv\(dest\)\n' '\1'
mut "S3 the delete's vault open ignores the chip secret" 'dk = openVaultDKSE\(v, name, pass, se\)' 'dk = openVaultDK(v, name, pass)'
mut "S4 the chip secret is handed to any typed creds" '(func deleteSessionSE\([^\n]*\n)\tif name != loginName \|\| pass != loginPass \{\n\t\treturn nil\n\t\}\n' '\1'

[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
