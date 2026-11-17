#!/usr/bin/env bash
# test-free-refusal-counts.sh [--mutate] -- runs the free-refusal-counts cases (free_refusal_counts_test.go;
# NWP-20261203-19, h64): a free renewal refused 402 logs the gateway's live bytes and free allowance beside the MiB and
# refs that renewal named (login.log only, Q008). --mutate re-runs them against a COPY of the package with each part
# broken in turn; the tree is never touched. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to
# apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestFreeRefusalCounts|TestPayRentAsksTheGatewayWhenTheWalletLooksFree' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - "$file" "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
# M1: _PayRent402 and _EntitlementDown convict it.
mut "M1 the clause not appended on a 402" billing.go \
  "$(one "r'counts = \"; \" \+ freeRefusalCounts\(ent, entOK, refs\)'" "'_ = freeRefusalCounts(ent, entOK, refs)'")"
# M2: _PayRent402 and _Helper convict it.
mut "M2 U taken from the renewal's sum, not ent.UsedBytes" billing.go \
  "$(one "r'ent\.UsedBytes>>20'" "'s>>20'")"
# M3: _EntitlementDown and _Helper convict it.
mut "M3 the unread arm prints U=0" billing.go \
  "$(one "r'\tif !entOK \{\n\t\treturn \"gateway count unread; \" \+ names\n\t\}\n'" "''")"
# M4: _PayRent402 convicts it (leaseBatchRefs = 3, so the first batch is not the whole renewal).
mut "M4 S summed over the first batch only" billing.go \
  "$(one "r'freeRefusalCounts\(ent, entOK, refs\)'" "'freeRefusalCounts(ent, entOK, batches[0])'")"
# M5: _OtherStatusUnchanged convicts it.
mut "M5 the clause appended for every non-200" billing.go \
  "$(one "r'if code == http\.StatusPaymentRequired \{\n(\t+)counts'" "lambda m: 'if code != http.StatusOK {\n' + m.group(1) + 'counts'")"
# M6: TestPayRentAsksTheGatewayWhenTheWalletLooksFree (free_latch_test.go, a pre-existing guard) convicts it.
mut "M6 the hoisted routing rule ignores EntitledBytes" billing.go \
  "$(one "r'if eerr == nil && ent\.EntitledBytes > 0 \{\n\t\t\tfreeUser = false'" "'if eerr == nil {\n\t\t\tfreeUser = false'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
