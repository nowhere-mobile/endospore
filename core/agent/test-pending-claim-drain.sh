#!/usr/bin/env bash
# test-pending-claim-drain.sh [--mutate] -- runs pending_claim_drain_test.go (NWP-20261202-01, h53 #6 slice 2, the drain
# half; h55 #1's webhook-lag edge): a sign-in whose wallet holds pending claim codes arms one drain that waits a random
# 10-40 minutes and sends nothing before that moment; it fires only while the armed session and wallet generation stand,
# the session is not local or cold-locked, no restart runs and no session operation holds sessionMu; it holds sessionMu
# to its publish, so no session swap lands mid-drain; one publish carries the tokens and the clear; an empty answer with
# nothing landed is kept once (its hash in pending_claim_misses) and cleared at the next session; the merges carry a
# miss only while its code is pending. --mutate re-runs the tests with each rule broken in turn and restores the files on
# exit. A mutant is CONVICTED only by a `--- FAIL` of the test its label names; one that does not apply, or that breaks
# the build, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(pending_claim_drain.go pending_claim.go billing.go wallet_restore.go)
restore() {
  local f
  for f in "${FILES[@]}"; do
    if [ -f "$W/$f.orig" ]; then cp "$W/$f.orig" "$f"; fi
  done
  rm -rf "$W"
}
trap restore EXIT
RUN=(go test -count=1 -run 'TestPendingDrain_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <convicting test> <file> <python-regex pattern> <replacement> [<pattern> <replacement> ...]
  local label="$1" want="$2" file="$3"
  shift 3
  python3 - "$file" "$@" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p=sys.argv[1]
s=open(p).read()
pairs=sys.argv[2:]
for i in range(0,len(pairs),2):
    s,c=re.subn(pairs[i],pairs[i+1],s,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(p,'w').write(s)
PY
  local res mrc nl=$'\n'
  res=$("${RUN[@]}" 2>&1); mrc=$?
  if score_mutant "$label" "$mrc" "$res"; then
    if [[ "$nl$res" != *"$nl--- FAIL: $want "* ]]; then
      echo "    ...but not by $want"
      fails=$((fails+1))
    fi
  else
    fails=$((fails+1))
  fi
  cp "$W/$file.orig" "$file"
}
mut "a the wait before the fire removed (NoRequestBeforeTheMoment)" TestPendingDrain_NoRequestBeforeTheMoment \
  pending_claim_drain.go 'pendingDrainSleep\(pendingDrainDelay\(\)\)' '_ = pendingDrainDelay'
mut "b the random draw fixed to 0 (DelayIsRandomAndBounded)" TestPendingDrain_DelayIsRandomAndBounded \
  pending_claim_drain.go 'pendingDrainMin \+ time\.Duration\(n\.Int64\(\)\)' 'pendingDrainMin + time.Duration(0*n.Int64())'
mut "c the session-name check removed (SessionEndedFirstSendsNothing)" TestPendingDrain_SessionEndedFirstSendsNothing \
  pending_claim_drain.go 'if n != name \{' 'if false && n != name {'
mut "d the wallet-generation check removed (ANewSignInFirstSendsNothing)" TestPendingDrain_ANewSignInFirstSendsNothing \
  pending_claim_drain.go 'if wgen != gen \{' 'if false && wgen != gen {'
mut "e the local-session check removed (LocalSessionSendsNothing)" TestPendingDrain_LocalSessionSendsNothing \
  pending_claim_drain.go 'if localOnlySession\(dest\) \{' 'if false && localOnlySession(dest) {'
mut "f the first empty answer clears at once (UnknownIsRetriedOnceAtTheNextSession)" TestPendingDrain_UnknownIsRetriedOnceAtTheNextSession \
  pending_claim.go 'if codeLanded > 0 \|\| missed\[pendingClaimSeenKey\(code\)\] \{' 'if true {'
mut "g the merges drop the miss (MergeCarriesTheMiss)" TestPendingDrain_MergeCarriesTheMiss \
  pending_claim.go '(func pendingClaimMissesFor\(.*?)\treturn out\n' '\1\treturn nil\n'
mut "h the wallet publish removed (NoRequestBeforeTheMoment)" TestPendingDrain_NoRequestBeforeTheMoment \
  pending_claim_drain.go 'if sealClaimedWallet\(dest, name, pass, got, wgen\) \{' 'if false {'
mut "i the fire does not hold sessionMu (ASessionSwapMidDrainWaitsForThePublish)" TestPendingDrain_ASessionSwapMidDrainWaitsForThePublish \
  pending_claim_drain.go 'if !sessionMu\.TryLock\(\) \{' 'if false {' \
  '\tdefer sessionMu\.Unlock\(\) // the whole fire: no sign-out or sign-in until it ends\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
