#!/usr/bin/env bash
# test-media-restart.sh [--mutate] -- runs media_restart_test.go (NWP-20261202-20: MEDIA-RESTART, a health notice's Fix
# for a session MediaProvider that stopped answering); --mutate re-runs it against a COPY of the package with each part
# broken in turn. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as
# a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run '^TestMediaRestart' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement> <the test that must convict it>: apply to the copy, run the suite
# there, require that test's own `--- FAIL`, then restore the file.
mut() {
  local label="$1" f="$2" conv="$5" res
  cp "$P/$f" "$W/orig.go"
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p,encoding='utf-8').read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w',encoding='utf-8').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *"--- FAIL: $conv"* ]]; then echo "  convicted $label (by $conv)"
    else echo "  SURVIVED  $label (wanted --- FAIL: $conv)"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 the caller check is removed" media_restart.go \
  'peer < 0 \|\| strconv\.Itoa\(peer/100000\) != uid' 'false && peer == strconv.IntSize' TestMediaRestartDeniesUser0AndOtherUsers
mut "M2 the wait for a running save is removed" media_restart.go \
  'for anySealRunning\(time\.Now\(\)\) \{' 'for false && anySealRunning(time.Now()) {' TestMediaRestartWaitsForASave
mut "M3 the pending dedupe is removed" media_restart.go \
  'if mediaRestartPending\.CompareAndSwap\(false, true\) \{' 'if mediaRestartPending.Swap(true) || true {' TestMediaRestartTwoTapsOneDispatch
mut "M4 the session re-check before dispatch is removed" media_restart.go \
  'if now != uid \{' 'if false && now != uid {' TestMediaRestartSessionEndedDrops
mut "M5 laneFor sends mediarestart to the read-only lane" main.go \
  'case "storagebreakdown", ' 'case "mediarestart", "storagebreakdown", ' TestMediaRestartRidesTheReadWriteLane
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
