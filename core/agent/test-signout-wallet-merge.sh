#!/usr/bin/env bash
# test-signout-wallet-merge.sh [--mutate] -- the by-value wallet publish merges the stored copy (NWP-20261128-13, the
# Q107 rule of NWP-20261031-01): sealWalletValueDurable, which publishes the sign-out, payRent's spend and a create's
# staged claim, keeps a token another handset added to the store and leaves a token this session spent out.
# Plain: the focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT
# copy and runs the same focused set there; each must be CONVICTED by the named `--- FAIL` of both tests. The working
# tree is never edited. A mutant that fails to apply (its literal must occur exactly once) or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='SignOutWalletMerge|LogoutWallet_'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>... (old must occur exactly once)
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want d
  shift 4
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R "$SRC/." "$d/"
  python3 - "$d/$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(cd "$d" && go test -count=1 -run "$FOCUS" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  rm -rf "$d"
}
T1=TestSignOutWalletMerge_KeepsTheOtherHandsetsTokensAndLeavesASpentOneOut
T2=TestSignOutWalletMerge_PayRentsByValuePublishMergesToo
mut "S1 the by-value publish merges with no seen-set" billing.go \
  ', w, walletSeen(walletPath, gen))' ', w, nil)' "$T1" "$T2"
mut "S2 the by-value publish reads no stored copy" billing.go \
  'walletForPublish(readStoredWallet(base, name, pass, dk), w,' 'walletForPublish(nil, w,' "$T1" "$T2"
mut "S3 the by-value publish drops the merge" billing.go \
  'if merged := walletForPublish(readStoredWallet(base, name, pass, dk), w, walletSeen(walletPath, gen)); merged != nil {' \
  'if merged := (*Wallet)(nil); merged != nil {' "$T1" "$T2"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
