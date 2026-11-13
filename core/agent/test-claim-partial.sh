#!/usr/bin/env bash
# test-claim-partial.sh [--mutate] -- runs claim_partial_test.go (NWP-20261201-21; decided 2026-11-06, h60 #15): an
# Add-credits drain cut short before the proving 402 answers PARTIAL <n>[ UNSAVED] and keeps its code in pending_claims,
# saved before the wallet publish that carries its tokens; a keep that fails still answers PARTIAL, saves nothing and
# logs a fixed outcome, never the code; a complete drain answers OK and clears no held code. --mutate re-runs the tests
# with each rule broken in turn and restores the files on exit. A mutant is CONVICTED only by a `--- FAIL` of the test
# that names it; one that does not apply, or that breaks the build, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(billing.go pending_claim.go main.go)
restore() {
  local f
  for f in "${FILES[@]}"; do
    if [ -f "$W/$f.orig" ]; then cp "$W/$f.orig" "$f"; fi
  done
  rm -rf "$W"
}
trap restore EXIT
RUN=(go test -count=1 -run 'TestClaimPartial' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement> <convicting test>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  if score_mutant "$1" "$mrc" "$res"; then
    if [[ "$res" != *"--- FAIL: $5"* ]]; then
      echo "  WRONG TEST $1 -- no \`--- FAIL: $5\` in its run"
      fails=$((fails+1))
    fi
  else
    fails=$((fails+1))
  fi
  cp "$W/$2.orig" "$2"
}
mut "M1 the err arm answers partial=false" billing.go \
  'return total, true, nil( // keep what already landed)' 'return total, false, nil\1' \
  'TestClaimPartial_T6_DrainOutcome/err_arm'
mut "M2 the default arm answers partial=false" billing.go \
  'return total, true, nil(\n\t\t\t\}\n\t\t\treturn 0, false, fmt\.Errorf\("issue: HTTP %d", code\))' 'return total, false, nil\1' \
  'TestClaimPartial_T1_PartialKeepsTheCode'
mut "M3 the proving 402 answers partial=true" billing.go \
  'return total, false, nil( // nothing left to claim)' 'return total, true, nil\1' \
  'TestClaimPartial_T2_CompleteAnswersOK'
mut "M4 handleClaimMode drops the keep" main.go \
  'keepPendingClaim\(capWalletPath\(\), code\)' 'error(nil)' \
  'TestClaimPartial_T1_PartialKeepsTheCode'
mut "M5 the PARTIAL reply is printed as OK" main.go \
  'reply = "PARTIAL"' 'reply = "OK"' \
  'TestClaimPartial_T1_PartialKeepsTheCode'
mut "M6 keepPendingClaim has no held check" pending_claim.go \
  '(func keepPendingClaim.*?)\tfor _, c := range w\.PendingClaims \{.*?\n\t\}\n' '\1' \
  'TestClaimPartial_T3_RedeemedTwiceHoldsItOnce'
mut "M7 keepPendingClaim saves on a busy lock" pending_claim.go \
  '(func keepPendingClaim.*?defer unlock\(\)\n)' '\1\tif state == walletLockBusy {\n\t\tstate = walletLocked\n\t}\n' \
  'TestClaimPartial_T5_BusyKeepStillAnswersPartial'
mut "M8 the log line prints the code" main.go \
  'partial -- the code %s\\n", n, kept\)' 'partial -- the code %s\\n", n, kept+" "+code)' \
  'TestClaimPartial_T5_BusyKeepStillAnswersPartial'
mut "M9 the keep moved after the seal" main.go \
  '(\treply := "OK"\n\tif partial \{.*?\n\t\} else \{\n\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] add-credits: \+%d token\(s\)\\n", n\)\n\t\}\n)(.*?saved = true // throwaway[^\n]*\n\t\}\n)' '\2\1' \
  'TestClaimPartial_T7_KeepRidesTheSeal'
mut "M10 the busy arm answers partial=false" billing.go \
  'return total, true, nil( // what landed is saved)' 'return total, false, nil\1' \
  'TestClaimPartial_T6_DrainOutcome/busy_arm'
mut "M11 the UNSAVED reply says OK" main.go \
  '"%s %d UNSAVED\\n", reply, n' '"OK %d UNSAVED\\n", n' \
  'TestClaimPartial_T8_SealFailureAnswersPartialUnsaved'
mut "M12 a complete drain clears a held code" main.go \
  '(\t\} else \{\n)(\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] add-credits: \+%d token\(s\)\\n", n\)\n)' '\1\t\tif w, e := loadWallet(capWalletPath()); e == nil {\n\t\t\tw.PendingClaims = nil\n\t\t\tsaveWallet(capWalletPath(), w)\n\t\t}\n\2' \
  'TestClaimPartial_T9_ACompleteDrainDoesNotClearAHeldCode'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
