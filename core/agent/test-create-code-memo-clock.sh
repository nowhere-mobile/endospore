#!/usr/bin/env bash
# test-create-code-memo-clock.sh [--mutate] -- runs the recovery-code memo tests (NWP-20261123-28: the Q048 / h46 #7
# memo measures its 5-minute window on CLOCK_BOOTTIME, so time asleep counts, and keeps no words when that clock cannot
# be read); --mutate re-runs them against copies of create_code_memo.go with each piece broken in turn, injected with
# `go test -overlay`, so the source tree is never edited. Each mutant must be CONVICTED by a real `--- FAIL`; one that
# does not apply, does not compile, or dies without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'CreateCodeMemo|PromoteCodeMemo' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <old text> <new text>: replaces the FIRST exact match in create_code_memo.go
  local label="$1" src=create_code_memo.go m="$W/mut.go" ov="$W/overlay.json" out
  python3 - "$src" "$m" "$2" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import sys
src,dst,old,new=sys.argv[1:5]
s=open(src).read()
if old not in s: sys.exit(1)
open(dst,'w').write(s.replace(old,new,1))
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run 'CreateCodeMemo|PromoteCodeMemo' . 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "M1 the memo reads Go's monotonic clock" 'createCodeMemoNow = createCodeMemoClock' 'createCodeMemoNow = time.Now'
mut "M2 an unreadable boot clock falls back to time.Now" $'\treturn time.Time{}\n}' $'\treturn time.Now()\n}'
mut "M3 createCodeMemoClock ignores bootNowMs" $'if ms := bootNowMs(); ms > 0 {\n\t\treturn time.UnixMilli(ms)\n\t}\n\treturn time.Time{}' 'return time.Now()'
mut "M4 rememberCode stores on a zero clock" $'\tif now.IsZero() {\n\t\treturn\n\t}\n' ''
mut "M5 takeCode hands words out on a zero clock" $'\tif createCodeMemoNow().IsZero() {\n\t\treturn ""\n\t}\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
