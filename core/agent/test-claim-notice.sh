#!/usr/bin/env bash
# test-claim-notice.sh [--mutate] -- runs claim_notice_test.go (NWP-20261208-03; decided 2026-11-03, h55 #1, h53 #6
# slice 3, the agent half): when the deferred drain clears a code on its second empty answer with nothing landed and the
# profile is then on the free plan, the same save records the code's hash in Wallet.UnusableClaims (never the code); a
# code that landed tokens, or a wallet with credit or any plan, leaves none; walletForPublish and mergeLateRestore carry
# a notice once and never bring back an acknowledged one; GET-CLAIM-NOTICE and CLAIM-NOTICE-SHOWN serve it. --mutate
# re-runs the tests against copies of the sources with each rule broken in turn, injected with `go test -overlay`, so
# the source tree is never edited. A mutant is CONVICTED only by a `--- FAIL` of the test its label names; one that does
# not apply, does not compile, or dies without a FAIL line is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestClaimNotice' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <convicting test> <file> <python-regex pattern> <replacement>
  local label="$1" want="$2" src="$3" m ov res mrc nl=$'\n'
  m=$(mktemp -p "$W" mut.XXXXXX) || exit 2
  ov=$(mktemp -p "$W" overlay.XXXXXX) || exit 2
  python3 - "$src" "$m" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! res=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$res"; fails=$((fails+1)); return
  fi
  res=$("${RUN[@]:0:3}" -overlay "$ov" "${RUN[@]:3}" 2>&1); mrc=$?
  if score_mutant "$label" "$mrc" "$res"; then
    if [[ "$nl$res" != *"$nl--- FAIL: $want "* ]]; then
      echo "    ...but not by $want"
      fails=$((fails+1))
    fi
  else
    fails=$((fails+1))
  fi
}
mut "X1 the notice on every clear (LandedThenEmptyNoNotice)" TestClaimNotice_LandedThenEmptyNoNotice \
  pending_claim.go 'if codeLanded == 0 \{' 'if true {'
mut "X2 claimNoticeFree always true (NotFreeNoNotice)" TestClaimNotice_NotFreeNoNotice \
  claim_notice.go 'return w\.balance\(\) == 0 &&[^\n]*' 'return true'
mut "X3 walletForPublish carries stored notices without the seen filter (AckedNotResurrected)" TestClaimNotice_AckedNotResurrected \
  billing.go '!have\[k\] && !seen\[k\] \{(?=\n\t+have\[k\] = true\n\t+out\.UnusableClaims)' '!have[k] {'
mut "X4 walletForPublish appends stored notices without the dedup (TwoPhonesOneNotice)" TestClaimNotice_TwoPhonesOneNotice \
  billing.go '!have\[k\] && !seen\[k\] \{(?=\n\t+have\[k\] = true\n\t+out\.UnusableClaims)' '!seen[k] {'
mut "X5 mergeLateRestore drops the notices (TwoPhonesOneNotice)" TestClaimNotice_TwoPhonesOneNotice \
  wallet_restore.go 'haveNotice\[k\] = true\n\t+out\.UnusableClaims = append\(out\.UnusableClaims, k\)' 'haveNotice[k] = true'
mut "X6 CLAIM-NOTICE-SHOWN clears every notice (Verbs)" TestClaimNotice_Verbs \
  claim_notice.go 'w\.UnusableClaims\[n:\]' 'w.UnusableClaims[len(w.UnusableClaims):]'
mut "X7 GET-CLAIM-NOTICE always NONE (Verbs)" TestClaimNotice_Verbs \
  claim_notice.go 'fmt\.Fprintf\(conn, "NOTICE %d\\n", len\(w\.UnusableClaims\)\)' 'fmt.Fprint(conn, "NONE\n")'
mut "X8 the notice is the code, not its hash (UnknownLeavesTheNotice)" TestClaimNotice_UnknownLeavesTheNotice \
  pending_claim.go 'unusableClaimKey\(c\)' 'c'
mut "X9 claimNoticeFree also requires PaidThrough in the past (UnknownLeavesTheNotice)" TestClaimNotice_UnknownLeavesTheNotice \
  claim_notice.go 'w\.AccountPlanGB == 0\n' $'w.AccountPlanGB == 0 && w.PaidThrough < nowEpoch()\n'
mut "X10 claimNoticeFree without the plan terms (NotFreeNoNotice)" TestClaimNotice_NotFreeNoNotice \
  claim_notice.go ' && w\.PlanGB == 0 && w\.AccountPlanGB == 0' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
