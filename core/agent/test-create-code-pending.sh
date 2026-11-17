#!/usr/bin/env bash
# test-create-code-pending.sh [--mutate] -- runs the CREATE-CODE pending-claim cases (create_code_pending_test.go;
# NWP-20261207-01, h53 #6 slice 2, the create half) and the claim code shape cases (claim_code_shape_test.go):
# CREATE-CODE stages its code as a pending claim beside the create and the create publishes it with the new profile's
# wallet; no request carries the code before a later session's randomised drain (NOWHERE-1748). A well-formed unknown
# code creates a free profile (h55 #1); a malformed one answers ERR-NOCODE before anything.
# --mutate re-runs them against main.go with one change broken in turn, restoring the file on exit. Each mutant names
# the ONE test that must convict it and counts only a `--- FAIL: <that test>` line; a mutant that fails to apply or
# to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=main.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestCreateCodePending_|TestClaimCodeShape_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <id> <label> <want: the test that must fail>; the mutation itself is <id> in the python below
  local id=$1 label=$2 want=$3 res
  python3 - "$F" "$id" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import sys
p, mid = sys.argv[1:3]
s = open(p).read()
k = "\tif err := keepPendingClaim(staged, code); err != nil {\n"
wf = "\tif !claimCodeWellFormed(code) {\n"
def once(*a): return all(s.count(x) == 1 for x in a)
n = None
if mid == "C1" and once(k):  # the drain back before the create, its result ignored
    n = s.replace(k, "\t_, _ = drainClaim(newGatewayClient(gw, gwDefault), staged, code, false)\n" + k, 1)
if mid == "C2" and once(k):  # the keep call removed
    n = s.replace(k, "\t_ = staged\n\tif err := error(nil); err != nil {\n", 1)
if mid == "C3" and once(k):  # the code kept into wallet.json instead of the staging
    n = s.replace(k, "\t_ = staged\n\tif err := keepPendingClaim(capWalletPath(), code); err != nil {\n", 1)
if mid == "C4" and once(k):  # a keep error ignored: createAndReply runs anyway
    n = s.replace(k, "\tif err := keepPendingClaim(staged, code); err != nil && false {\n", 1)
if mid == "C5" and once(wf):  # the shape check removed
    n = s.replace(wf, "\tif false && !claimCodeWellFormed(code) {\n", 1)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
  else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
  cp -f "$W/$F.orig" "$F"
}
mut C1 "C1 the drain back before the create" TestCreateCodePending_NoRequestCarriesTheCode
mut C2 "C2 the keepPendingClaim call removed" TestCreateCodePending_TheHeadCarriesTheCode
mut C3 "C3 the code kept into wallet.json instead of the staging" TestCreateCodePending_TheHeadCarriesTheCode
mut C4 "C4 a keep error ignored" TestCreateCodePending_BusyStagingCreatesNothing
mut C5 "C5 the claimCodeWellFormed check removed" TestClaimCodeShape_CreateCodeRefusesBeforeAnything
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
