#!/usr/bin/env bash
# test-store-stall-retry.sh [--mutate] -- runs store_stall_retry_test.go (NWP-20261210-02, backlog §B "A large app's
# fetch fails on a slow link: one chunk with no data for 30 s ends the whole fetch, and each retry starts again from
# chunk 1"): a chunk GET cut by storeXferStall while the link carried bytes is retried past the retry window, at most
# storeStallRetries times, and a body byte counts as the store answering for the sign-in / delete give-up clock.
# --mutate re-runs the convicting tests against broken copies of main.go, store_xfer.go and store_giveup.go, injected
# with `go test -overlay`, so the source tree is never edited. Each mutant must be CONVICTED by a `--- FAIL` line of
# every test named beside it; a mutant that does not apply, or does not compile, is a failure. The control (a comment
# edit) must pass.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN='StallRetry|StoreGiveUpBytes|SignInRestoreSurvivesAStall|StoreXferBodyNotesBytes'
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <python-regex pattern> <replacement> <test>... -- every named test must print `--- FAIL: <test>`.
mut() {
  local label="$1" file="$2" pat="$3" rep="$4" m ov res rc t re missing=""
  shift 4
  m=$(mktemp -p "$W" mut.XXXXXX.go) || exit 2
  ov=$(mktemp -p "$W" overlay.XXXXXX.json) || exit 2
  if ! python3 - "$file" "$pat" "$rep" "$m" <<'PY'
import re, sys
src, pat, rep, dst = sys.argv[1:5]
s = open(src).read()
n, c = re.subn(pat, lambda x: x.expand(rep), s, count=1, flags=re.S)
if c != 1 or n == s:
    sys.exit(1)
open(dst, 'w').write(n)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return
  fi
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$file" "$m" >"$ov"
  re=$(IFS='|'; echo "$*")
  res=$(go test -count=1 -overlay "$ov" -run "^($re)\$" . 2>&1); rc=$?
  if [[ "$label" != C* ]]; then
    for t in "$@"; do
      [[ $'\n'"$res" == *$'\n''--- FAIL: '"$t "* ]] || missing="$missing $t"
    done
    if [ "$rc" -ne 0 ] && [ -z "$missing" ]; then echo "  convicted $label"
    else
      if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $label -- did not compile"
      else echo "  SURVIVED  $label -- no --- FAIL from:$missing"; fi
      tail -n 15 <<<"$res"
      fails=$((fails+1))
    fi
  else # the control must pass
    if [ "$rc" -eq 0 ]; then echo "  passed    $label (control)"
    else echo "  FAILED    $label (control) -- a comment edit failed the tests"; tail -n 15 <<<"$res"; fails=$((fails+1)); fi
  fi
}

mut "X1 Read no longer calls noteStoreBytes" store_xfer.go \
  '\t\tnoteStoreBytes\(\) // NWP-20261210-02[^\n]*\n' '' \
  TestSignInRestoreSurvivesAStallPastTheGiveUpWindow TestStoreXferBodyNotesBytes
mut "X2 noteStoreBytes stamps but records no answer" store_giveup.go \
  '\tstoreGiveUp\.failingSince = time\.Time\{\} // a body byte is the store answering\n\tstoreGiveUp\.answeredAt = now\n' '' \
  TestStoreGiveUpBytesAreAnswers
mut "X3 the exemption removed" main.go \
  'if errors\.Is\(err, errStoreXferStall\) && storeXferByteAt\.Load\(\) >= t0\.UnixNano\(\) && stallRetries < storeStallRetries \{' \
  'if false {' \
  TestStallRetryWhileLinkCarriesBytes
mut "X4 the byte condition dropped" main.go \
  ' && storeXferByteAt\.Load\(\) >= t0\.UnixNano\(\) && stallRetries' ' && stallRetries' \
  TestStallRetryDeadLinkKeepsTheWindow
mut "X5 storeXferByteAt compared with 0, not t0" main.go \
  'storeXferByteAt\.Load\(\) >= t0\.UnixNano\(\)' 'storeXferByteAt.Load() > 0' \
  TestStallRetryStaleBytesDoNotCount
mut "X6 the errStoreXferStall condition dropped" main.go \
  'if errors\.Is\(err, errStoreXferStall\) && storeXferByteAt' 'if storeXferByteAt' \
  TestStallRetryOnlyForStall
mut "X7 the storeStallRetries bound removed" main.go \
  ' && stallRetries < storeStallRetries \{' ' { _ = storeStallRetries' \
  TestStallRetryIsBounded
mut "X8 Read notes on n == 0" store_xfer.go \
  '(\tn, err := b\.rc\.Read\(p\)\n)' '\1\tnoteStoreBytes()\n' \
  TestStoreXferBodyNotesBytes
mut "C1 a comment edit" main.go \
  '// NWP-20261210-02: attempts started past the window' '// NWP-20261210-02: the attempts started past the window' \
  TestStallRetryWhileLinkCarriesBytes TestStallRetryIsBounded
[ "$fails" -eq 0 ] && echo "== all mutations convicted, the control passed" || { echo "== $fails mutation(s) not convicted"; exit 1; }
