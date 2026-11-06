#!/usr/bin/env bash
# test-push-clock.sh [--mutate] -- runs the TestPushClock tests in push_clock_test.go (NWP-20261117-33): a push's
# summary and its upload figure (pushSplit) name the wall time and the minutes asleep beside the monotonic time,
# which stops in suspend; a seal whose clocks agree within a second logs exactly as before; a wall below mono is
# clamped; both summary lines and capFlush take one monotonic and one Round(0) reading on each end.
# --mutate re-runs them against main.go and push_clock.go with each rule broken in turn, restoring both files on exit
# (the pristine copies live in one scratch root, never beside the source). Each mutant must be CONVICTED by a real
# `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" main.go; [ -f "$W/push_clock.go.orig" ] && cp -f "$W/push_clock.go.orig" push_clock.go; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestPushClock' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
vet=$(go vet ./... 2>&1); vrc=$?
if [ "$vrc" -ne 0 ]; then printf '%s\n' "$vet"; echo "FAIL: go vet ./..."; exit 1; fi
echo "ok: go vet ./..."
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp push_clock.go "$W/push_clock.go.orig"
fails=0
# sub <file> <count> <python regex> <replacement> -- replaces every match; exactly <count> matches must exist.
sub() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import re,sys
p,n,pat,rep=sys.argv[1:5]
s=open(p).read()
t,c=re.subn(pat,lambda m: rep,s)
if c!=int(n): sys.exit(1)
open(p,'w').write(t)
PY
}
# mut <label> <file> <count> <pattern> <replacement> [<file> <count> <pattern> <replacement> ...]
mut() {
  local label=$1 res rc
  shift
  while [ "$#" -ge 4 ]; do
    if ! sub "$1" "$2" "$3" "$4"; then
      echo "  INERT     $label -- the mutation did not apply ($1: $3)"; fails=$((fails+1))
      cp -f "$W/main.go.orig" main.go; cp -f "$W/push_clock.go.orig" push_clock.go
      return
    fi
    shift 4
  done
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/main.go.orig" main.go
  cp -f "$W/push_clock.go.orig" push_clock.go
}
mut "M1 pushProfile's wall time computed from monotonic readings" \
  main.go 1 't0w := t0\.Round\(0\)' 't0w := t0' \
  main.go 2 'time\.Now\(\)\.Round\(0\)\.Sub\(t0w\)' 'time.Now().Sub(t0w)'
mut "M2 capFlush's wall time computed from monotonic readings" \
  main.go 1 'tFlushW := tFlush\.Round\(0\)' 'tFlushW := tFlush' \
  main.go 1 'time\.Now\(\)\.Round\(0\)\.Sub\(tFlushW\)' 'time.Now().Sub(tFlushW)'
mut "M3 asleep not clamped" \
  push_clock.go 1 '\n\t\tasleep = 0\n' $'\n\t\t_ = 0\n'
mut "M4 the scope line left on the old format" \
  main.go 1 'gen %s %s \[%s\]\\n",\n(.*)pushClock\(time\.Since\(t0\), time\.Now\(\)\.Round\(0\)\.Sub\(t0w\)\), pushSplit\(t0\)\)' \
  'gen %s in %s [%s]\n",
				logProfile(profile), len(chunks), atomic.LoadInt64(&blobCacheHits), atomic.LoadInt64(&contentCacheHits), short(manifestHash), time.Since(t0).Round(time.Millisecond), pushSplit(t0))'
mut "M5 pushSplit drops the upload's wall note" \
  main.go 1 'sleepNote\(up, upw\)' 'sleepNote(upw, upw)'
mut "M6 the sub-second rule is dropped" \
  push_clock.go 1 'd < time\.Second' 'd < time.Millisecond'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
