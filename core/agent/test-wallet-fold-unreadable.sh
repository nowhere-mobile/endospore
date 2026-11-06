#!/usr/bin/env bash
# test-wallet-fold-unreadable.sh [--mutate] -- the cap-mode fold writes no #wallet head while the stored wallet cannot be
# read (NWP-20261107-02, dn-1031 #1, decided 2026-10-21, option (b)): a store hiccup on handset B's read no longer
# publishes B's local set over the tokens handset A claimed. Absence and a damaged copy still publish. Plain: the
# focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT copy and runs
# the same focused set there; each must be CONVICTED by the named `--- FAIL`. The working tree is never edited. A mutant
# that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='WalletFoldUnreadable'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> [<old> <new>]... -- <convicting test>... (every occurrence of old is replaced)
mut() {
  local label="$1" file="$2" res want d
  local -a pairs=()
  shift 2
  while [ $# -gt 0 ] && [ "$1" != -- ]; do pairs+=("$1"); shift; done
  shift
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R "$SRC/." "$d/"
  python3 - "$d/$file" "${pairs[@]}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p = sys.argv[1]
rest = sys.argv[2:]
s = open(p).read()
for old, new in zip(rest[0::2], rest[1::2]):
    if s.count(old) < 1:
        sys.exit(1)
    s = s.replace(old, new)
open(p, 'w').write(s)
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
U1=TestWalletFoldUnreadable_U1_AnUnreadableCopyIsNotOverwrittenByTheLocalSet
U3=TestWalletFoldUnreadable_U3_ADamagedCopyStillPublishesTheLocalSet
U4=TestWalletFoldUnreadable_U4_NoStoredWalletAtAllPublishesTheFirstFold
U5=TestWalletFoldUnreadable_U5_ASecondFoldWhoseReadFailsUnstagesTheFirst
U6=TestWalletFoldUnreadable_U6_ADurablePublishKeepsItsOwnHeadWhenTheReFoldCannotRead
U7=TestWalletFoldUnreadable_U7_ADurablePublishWhoseFoldCannotReadKeepsItsMergedHead
U8=TestWalletFoldUnreadable_U8_ADurablePublishWhoseEveryFoldCannotReadPublishesThePostSpendWallet
mut "W1 the skip removed: the local set publishes over an unreadable copy" main.go $'\t\tif !readable {' $'\t\tif false && !readable {' -- "$U1"
mut "W2 a damaged copy treated as unreadable" wallet_restore.go $'\tif walletDamage(err) {\n\t\treturn nil, true' $'\tif walletDamage(err) {\n\t\treturn nil, false' -- "$U3"
mut "W3 an absent copy treated as unreadable" wallet_restore.go $'\tif err == nil {\n\t\treturn w, true' $'\tif err == nil && w != nil {\n\t\treturn w, true' -- "$U4"
mut "W4 the skip placed after the staging" main.go $'\t\tif !readable {' $'\t\tif false && !readable {' $'\t\trefs["ref/"+wref] = int64(len(h))\n' $'\t\trefs["ref/"+wref] = int64(len(h))\n\t\tif !readable {\n\t\t\treturn\n\t\t}\n' -- "$U1"
mut "W5 the fold back on readStoredWallet's fail-soft read" main.go 'storedWalletForPublish("s3", foldName, sess.pass, foldDK)' 'readStoredWallet("s3", foldName, sess.pass, foldDK), true' -- "$U1" "$U7"
mut "W6 the unstaging keeps foldKey: the earlier snapshot is PUT" main.go $'\t\t\t\tfoldKey, foldBlob = "", nil' $'\t\t\t\t_ = foldBlob' -- "$U5"
mut "W7 a durable publisher never recognised: its re-fold that cannot read unstages its head" main.go 'publisherHead := sess.publisherCopy != nil' 'publisherHead := false && sess.publisherCopy != nil' -- "$U6" "$U8"
mut "W8 the fallback to a copy removed: a publisher's fold that cannot read stages nothing" main.go '} else if publisherHead && foldRead {' '} else if false && publisherHead && foldRead {' -- "$U6" "$U8"
mut "W9 the seed removed: a fold that cannot read before any fold has read leaves the pre-spend head" main.go 'foldStored, foldRead = sess.publisherCopy, true' 'foldStored, foldRead = nil, false' -- "$U8"
mut "W10 the fallback widened past a publisher's bracket" main.go '} else if publisherHead && foldRead {' '} else if foldRead || publisherHead {' -- "$U5"
mut "W11 the re-fold drops the publisher's own convergent blob from the lease set" main.go $'\t\t\tif b.key == foldKey {' $'\t\t\tif false && b.key == foldKey {' -- "$U8"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
