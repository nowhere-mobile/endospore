#!/usr/bin/env bash
# test-signout-side-files.sh [--mutate] -- a landed sign-out leaves no wallet side file in the state tmpfs
# (NWP-20261129-52): dropWalletIfUnchanged removes wallet.json.moving and a crash-left wallet.json.seen.tmp with the
# wallet, only after its lock, generation and bytes checks, and removeWallet removes the .seen.tmp too.
# Plain: the focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT
# copy and runs the same focused set there; each must be CONVICTED by the named `--- FAIL`. The working tree is never
# edited. A mutant that fails to apply (its literal must occur exactly once) or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='SignOutSideFiles'
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
D1=TestSignOutSideFiles_ALandedSignOutRemovesBoth
D2=TestSignOutSideFiles_RemoveWalletRemovesBoth
D3=TestSignOutSideFiles_ARefusedDropRemovesNothing
mut "R1 the marker left out of the drop" wallet_lock.go \
  $'\t\tplanMovingPath(walletPath),\n' '' "$D1"
mut "R2 the .seen.tmp left out of the drop" wallet_lock.go \
  'walletPath + ".seen.tmp", seenBadPath(walletPath),' 'seenBadPath(walletPath),' "$D1"
mut "R3 the .seen.tmp left out of removeWallet" wallet_lock.go \
  $'\tos.Remove(walletPath + ".seen.tmp")\n' '' "$D2"
mut "R4 the marker removed before the generation check" wallet_lock.go \
  $'\tif !walletAtGeneration(walletPath, gen) {\n' \
  $'\tos.Remove(planMovingPath(walletPath))\n\tif !walletAtGeneration(walletPath, gen) {\n' "$D3"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
