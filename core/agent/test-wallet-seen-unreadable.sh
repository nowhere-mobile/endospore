#!/usr/bin/env bash
# test-wallet-seen-unreadable.sh [--mutate] -- NWP-20261118-12 (Q107): a wallet seen-set that is there but cannot be read
# whole (an open error, an empty file, a failed scan) poisons its generation, as a failed write does; an absent set or
# one of another generation still starts afresh. Runs the focused Go tests; --mutate applies each mutant to a pristine
# copy of wallet_seen.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does
# not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp wallet_seen.go "$W/wallet_seen.go.orig" || exit 2
trap 'cp "$W/wallet_seen.go.orig" wallet_seen.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestWalletSeenUnreadable|TestWalletSeen_'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
restore_pristine() {
  cp "$W/wallet_seen.go.orig" wallet_seen.go
}
# mutate <label> <python body acting on s>: apply to a pristine wallet_seen.go, require a real --- FAIL
mutate() {
  local lbl="$1" body="$2" o r
  restore_pristine
  if ! python3 -c "
s = open('wallet_seen.go').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('wallet_seen.go','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); restore_pristine; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1); r=$?
  score_mutant "$lbl" "$r" "$o" || FAILS=$((FAILS+1))
  restore_pristine
}
echo "== mutations =="
mutate "S1: noteWalletSeen starts afresh on an unreadable set" "
t = s.replace('if st == seenUnreadable {', 'if false && st == seenUnreadable {', 1)"
mutate "S2: a set of another generation is classed unreadable" "
t = s.replace('return nil, seenOtherGen, nil', 'return nil, seenUnreadable, errSeenEmpty', 1)"
mutate "S3: the closing sc.Err() is ignored" "
t = s.replace('\tif err := sc.Err(); err != nil {\n\t\treturn nil, seenUnreadable, seenCause(err) // a line past the 16 MiB cap, or an I/O error\n\t}\n', '', 1)"
mutate "S4: an empty file is classed absent" "
t = s.replace('return nil, seenUnreadable, errSeenEmpty', 'return nil, seenAbsent, nil', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "4 mutants convicted"
