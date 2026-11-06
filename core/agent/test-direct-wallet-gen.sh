#!/usr/bin/env bash
# test-direct-wallet-gen.sh [--mutate] -- runs direct_wallet_gen_test.go (NWP-20261128-22): self-hosted sealWallet reads
# the wallet under the wallet lock after its bracket wait and publishes only the generation its entry check judged.
# --mutate re-runs it against a COPY of the package in $W (the working tree is never edited), with sealWallet broken
# in turn: D-a the g0 comparison removed, D-b the refusal returning nil (the publish still skipped), D-c the seen merge
# given no seen-set, D-d the locked read replaced by a plain read with no comparison. Each mutant must be CONVICTED by
# its named test's `--- FAIL`; one that does not apply, or does not compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -timeout 300s -run 'TestDirectWalletGen_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

PKG="$W/pkg"
mkdir "$PKG" || exit 2
cp -r ./* "$PKG"/ || exit 2
cp billing.go "$W/billing.go.orig" || exit 2
fails=0
# mut <label> <test that must FAIL> <regex> <replacement> [<regex> <replacement> ...]: every substitution is made
# once, inside sealWallet's body only (from "\nfunc sealWallet(" to the next "\n}\n").
mut() {
  local label="$1" want="$2" mout mrc
  shift 2
  cp -f "$W/billing.go.orig" "$PKG/billing.go"
  python3 - "$PKG/billing.go" "$@" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p=sys.argv[1]; rest=sys.argv[2:]
s=open(p).read()
i=s.index("\nfunc sealWallet("); j=s.index("\n}\n", i)
body=s[i:j]
for pat,rep in zip(rest[0::2],rest[1::2]):
    body,c=re.subn(pat,lambda _m:rep,body,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(p,'w').write(s[:i]+body+s[j:])
PY
  mout=$(cd "$PKG" && go vet . 2>&1) || { echo "  NOCOMPILE $label"; head -5 <<<"$mout"; fails=$((fails+1)); return; }
  mout=$(cd "$PKG" && "${RUN[@]}" 2>&1); mrc=$?
  if [ "$mrc" -ne 0 ] && [[ "$mout" == *"--- FAIL: $want "* ]]; then echo "  convicted $label"
  else echo "  SURVIVED  $label (rc=$mrc, no --- FAIL: $want)"; tail -n 15 <<<"$mout"; fails=$((fails+1)); fi
}
G1=TestDirectWalletGen_ASignInWhileItWaitsIsNotPublished
G3=TestDirectWalletGen_MergesTheStoredCopyBySeen
mut "D-a the g0 comparison removed" "$G1" 'if gen != g0 \{' 'if false {'
mut "D-b the refusal returns nil, the publish still skipped" "$G1" 'err = errWalletChangedHands' 'err = nil'
mut "D-c the seen merge given no seen-set" "$G3" 'walletSeen\(walletPath, gen\)' 'nil'
mut "D-d a plain read, the generation read after it, no comparison" "$G1" \
  '\n\t\tunlock, _ := lockWalletWithin\(walletPath, walletSignInWait\)' '' \
  '\n\t\tunlock\(\)' '' \
  'if gen != g0 \{' 'if false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
