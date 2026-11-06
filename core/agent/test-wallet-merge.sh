#!/usr/bin/env bash
# test-wallet-merge.sh [--mutate] -- two handsets signed in to one profile merge their wallets (NWP-20261031-01, decided
# 2026-10-20, Q107): a publish is this phone's tokens plus the stored copy's minus every token this session has held
# (the tmpfs seen-set, wallet_seen.go). Plain: the focused set. --mutate copies the package into the temp root for every
# mutant, applies the mutant to THAT copy and runs the same focused set there; each must be CONVICTED by the named
# `--- FAIL`. The working tree is never edited. A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='WalletPublish|WalletTwoWriter|WalletSeen|EveryWalletWriterTakesTheWalletLock|LateRestore'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>... (every occurrence of old is replaced)
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want d
  shift 4
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R "$SRC/." "$d/"
  python3 - "$d/$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) < 1:
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
TW=TestWalletTwoWriter_ClaimsOfBothHandsetsSurviveAndASpentTokenStaysSpent
mut "W1 no union: the local set publishes unchanged (today)" billing.go $'\tif seen != nil {\n\t\t// The tokens' $'\tif false && seen != nil {\n\t\t// The tokens' "$TW" TestWalletPublish_TheOtherPhonesNewCreditIsKept
mut "W2 the seen filter dropped: a plain union resurrects a spent token" billing.go ' && !seen[k] {' ' {' "$TW" TestWalletPublish_ASpentTokenIsNeverResurrected
mut "W3 saveWallet stops noting what it saves" billing.go $'\tif err := noteWalletSeen(path, w); err != nil {\n\t\treturn err\n\t}\n' '' "$TW" TestWalletSeen_AnotherGenerationIsIgnoredAndRemoveWalletRemovesIt
mut "W4 a blind token keyed by its signature" wallet_seen.go 'sha256.Sum256([]byte(t.Msg))' 'sha256.Sum256([]byte(t.Sig))' "$TW" TestWalletSeen_AnotherGenerationIsIgnoredAndRemoveWalletRemovesIt
mut "W5 removeWallet keeps the seen-set" wallet_lock.go $'\tos.Remove(walletPath + ".seen")\n' '' TestWalletSeen_AnotherGenerationIsIgnoredAndRemoveWalletRemovesIt
mut "W6 the poison marker is not read: another process recreates a short set" wallet_seen.go $'\traw, err := os.ReadFile(seenBadPath(walletPath))\n\treturn err == nil && strings.TrimSpace(string(raw)) == gen' $'\treturn false' TestWalletSeen_AFailedWriteIsRememberedAcrossProcesses
mut "W7 a failed marker write no longer refuses the save" wallet_seen.go $'\t\treturn fmt.Errorf("seen-set update failed' $'\t\treturn nil\n\t\t_ = fmt.Errorf("seen-set update failed' TestWalletSeen_AFailedMarkerWriteRefusesTheSave
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
