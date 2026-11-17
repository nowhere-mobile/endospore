#!/usr/bin/env bash
# test-restored-credit.sh [--mutate] -- runs wallet_restored_test.go (NWP-20261202-40, decided 2026-11-05, harvest 59
# #10): the gate's lost-credit notice fires only for a token the session's own sign-in did not restore, read from the
# tmpfs record of the restored token keys (wallet.json.restored, generation-keyed, no store read). --mutate re-runs it
# against copies of the agent's sources with the record or the predicate broken in turn, injected with
# `go test -overlay`, so the source tree is never edited. Each mutant must be CONVICTED by a `--- FAIL` line of each
# test it names; one that does not apply, does not compile, or fails without those lines counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestRestoredCredit_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <space-separated --- FAIL names it must show> <python-regex pattern> <replacement>
  local label="$1" file="$2" want="$3" m ov out n missing=""
  m=$(mktemp -p "$W" mut.XXXXXX) || exit 2
  ov=$(mktemp -p "$W" overlay.XXXXXX) || exit 2
  python3 - "$file" "$m" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
s,c=re.subn(pat,lambda _m:_m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$file" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$("${RUN[@]:0:3}" -overlay "$ov" "${RUN[@]:3}" 2>&1)
  for n in $want; do
    grep -q -- "--- FAIL: $n " <<<"$out" || missing="$missing $n"
  done
  if [ -z "$missing" ]; then
    echo "  convicted $label:$(printf ' %s' $want)"
  elif grep -q -- '--- FAIL' <<<"$out"; then
    echo "  SURVIVED  $label -- no --- FAIL for:$missing"; grep -- '--- FAIL' <<<"$out"; fails=$((fails+1))
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; tail -15 <<<"$out"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
P=TestRestoredCredit_
R4=${P}ARecordItCannotUseCountsEveryToken
mut "M1 the notice counts every token again" wallet_restored.go \
  "${P}RestoredOnlyIsNotToldLost ${P}ALateMergeRecordsTheStoredTokens" \
  '(func walletHoldsUnrestoredCredit\(wp string\) bool \{\n).*?\n\}\n' $'\\1\treturn walletHoldsCredit(wp)\n}\n'
mut "M2 a record of another generation is believed" wallet_restored.go "$R4 $R4/other_generation" \
  $'\tif sc.Text\\(\\) != gen \\{\n\t\treturn nil\n\t\\}\n' ''
mut "M3 the fresh landing records nothing" wallet_restore.go "${P}RestoredOnlyIsNotToldLost" \
  $'\t\tnoteWalletRestored\\(walletPath, &restored\\)[^\n]*\n' ''
mut "M4 the late merge records nothing" wallet_restore.go "${P}ALateMergeRecordsTheStoredTokens" \
  $'\t\tnoteWalletRestored\\(walletPath, &stored\\)[^\n]*\n' ''
mut "M5 the locked retry records nothing" wallet_restore.go "${P}ALockedRetryRecordsTheStoredTokens" \
  $'\t\tnoteWalletRestored\\(walletPath, stored\\)[^\n]*\n' ''
mut "M6 the no-keep sign-out counts every token" main.go "${P}RestoredOnlyIsNotToldLost" \
  $'if walletHoldsUnrestoredCredit\\(walletPathFor\\(dest\\)\\) \\{\n\t\tnoteCreditLost\\(dest\\) // BEFORE the switch' \
  $'if walletHoldsCredit(walletPathFor(dest)) {\n\t\tnoteCreditLost(dest) // BEFORE the switch'
mut "M7 removeWallet keeps the record" wallet_lock.go "${P}TheWalletRemovalsTakeTheRecord" \
  $'\tos.Remove\\(walletRestoredPath\\(walletPath\\)\\)\n' ''
mut "M8 the drop keeps the record" wallet_lock.go "${P}TheWalletRemovalsTakeTheRecord" \
  'walletRestoredPath\(walletPath\), (walletRestoredPath\(walletPath\) \+ "\.tmp",)' '\1'
mut "M9 no record means no credit" wallet_restored.go "$R4 $R4/other_generation $R4/directory" \
  "return walletHoldsCredit\\(wp\\) // no record: today's answer" 'return false'
mut "M10 an unreadable wallet counts as no credit" wallet_restored.go "$R4 $R4/unparsable_wallet" \
  $'(w, err := loadWallet\\(wp\\)\n\tif err != nil \\{\n\t\treturn )true' '\1false'
mut "M11 no wallet file counts as credit" wallet_restored.go "$R4 $R4/no_wallet_file" \
  $'(os.IsNotExist\\(err\\) \\{\n\t\treturn )false' '\1true'
mut "M12 an added token is never seen" wallet_restored.go \
  "${P}AnAddedTokenIsToldLost ${P}ALateMergeRecordsTheStoredTokens ${P}ALockedRetryRecordsTheStoredTokens" \
  'if !restored\[k\] \{' 'if false && !restored[k] {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
