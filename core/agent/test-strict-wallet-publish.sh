#!/usr/bin/env bash
# test-strict-wallet-publish.sh [--mutate] -- payRent's spend and a claim write no #wallet head while the stored wallet
# cannot be read (NWP-20261129-33, dn-1031 #1, decided 2026-10-21, option (b)): a store hiccup on this handset's read no
# longer publishes its local set over another handset's tokens. A damaged or absent copy still publishes. Plain: the
# focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT copy and runs
# the same focused set there; each must be CONVICTED by the named `--- FAIL`. The working tree is never edited. A mutant
# that fails to apply (its literal must occur exactly once) or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='StrictWalletPublish'
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
E1=TestStrictWalletPublish_E1_TheValueSiblingWritesNoHeadThenMerges
E2=TestStrictWalletPublish_E2_PayRentWritesNoHeadThenTheNextSaveMerges
E3=TestStrictWalletPublish_E3_TheClaimAnswersUnsavedThenMerges
E4=TestStrictWalletPublish_E4_ADamagedOrAbsentCopyStillPublishes
mut "X1 payRent back on the fail-soft publish" billing.go \
  '_, err = sealWalletValueDurableStrict(base,' '_, err = sealWalletValueDurable(base,' "$E2"
mut "X2 the claim back on the fail-soft publish" main.go \
  'sealWalletDurableStrict("s3", name, pass, dk, wp)' 'sealWalletDurable("s3", name, pass, dk, wp)' "$E3"
mut "X3 the strict read takes a damaged copy as unreadable" billing.go \
  'w, readable := storedWalletForPublish(base, name, pass, dk)' \
  'w, _, serr := readStoredWalletStrict(base, name, pass, dk); readable := serr == nil' "$E4"
mut "X4 the strict read never refuses" billing.go \
  'if !readable {' 'if false && !readable {' "$E1" "$E3"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
