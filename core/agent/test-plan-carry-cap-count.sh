#!/usr/bin/env bash
# test-plan-carry-cap-count.sh [--mutate] -- in cap mode the login-time plan-carry retry costs the ONE fused head-ref
# probe and no head-blob read (NWP-20261112-26). Plain: the cap-mode count, the non-cap retry test and the resolveDK
# tests. --mutate copies the package into one temp root, applies each mutant to the COPY (the tree is never touched),
# and needs `--- FAIL: TestPlanCarryRetry_CapModeReadsTheHeadRefOnceAndNoBlob` for each. A mutant that fails to apply
# or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'PlanCarryRetry_CapMode|TheLoginRetryDoesNotRefetchTheHead|ResolveDK' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

C=$(mktemp -d -p "$W") || exit 2
P=$(mktemp -d -p "$W") || exit 2
cp -r . "$C/" || exit 2
FILES=(main.go billing.go)
for f in "${FILES[@]}"; do cp "$f" "$P/$f" || exit 2; done
restore() { local f; for f in "${FILES[@]}"; do cp -f "$P/$f" "$C/$f"; done; return 0; }
WANT=TestPlanCarryRetry_CapModeReadsTheHeadRefOnceAndNoBlob
fails=0
# mut <label> <file> <old-literal> <new-literal>: <old-literal> must occur exactly once in <file>.
mut() {
  local label="$1" file="$2" old="$3" new="$4" res rc
  if ! python3 - "$C/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return
  fi
  res=$(cd "$C" && "${RUN[@]}" 2>&1); rc=$?
  if ! score_mutant "$label" "$rc" "$res"; then fails=$((fails+1))
  elif [[ "$res" != *"--- FAIL: $WANT"* ]]; then
    echo "  SURVIVED  $label -- failed, but not in $WANT"; fails=$((fails+1))
  fi
  restore
}
mut "M1 openVaultHead ignores have and always calls getRef (2 ref reads)" main.go \
  $'\tif !have {\n\t\tval = getRef(base, ref) // non-cap backends' \
  $'\tif _ = have; true {\n\t\tval = getRef(base, ref) // non-cap backends'
mut "M2 openVaultHead reads through getHeadBlob (1 blob read)" main.go \
  'return parseVault(headBlobGet(base, val))' 'return parseVault(getHeadBlob(base, val))'
mut "M3 refProbe returns haveVal=false in cap mode (2 ref reads)" main.go \
  'return true, strings.TrimSpace(string(b)), true' 'return true, strings.TrimSpace(string(b)), false'
mut "M4 resolveDK reads through getHeadBlob, the cache is never filled (1 blob read)" billing.go \
  'parseVault(headBlobGet(base, head)); isV' 'parseVault(getHeadBlob(base, head)); isV'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
