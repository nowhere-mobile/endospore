#!/usr/bin/env bash
# test-media-restore-wait.sh [--mutate] -- runs media_restore_wait_test.go and media_lander_run_test.go (NWP-20261207-11,
# backlog "A 179-second login, 95% of it bulk media restored INLINE before the gate opens", Q106 slice S6b half 1: mediad
# publishes RESTORE-WAITING while the lander is parked on transient fetch errors, docs/media-after-gate.md §6, §10 O3).
# --mutate re-runs it against a COPY of the package with one rule broken in turn. Each mutant must be CONVICTED by a
# `--- FAIL` of the test its label names; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestMediaRestoreWait|TestMediaBgRun' -v .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <test> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
# The mutant is convicted only when <test> itself fails.
mut() {
  local label="$1" want="$2" f="$3" res rc nl=$'\n'
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$4" "$5" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    if ! score_mutant "$label" "$rc" "$res"; then
      fails=$((fails+1))
    elif [[ "$nl$res" != *"$nl--- FAIL: $want "* ]]; then
      echo "  WRONG     $label -- convicted, but not by $want"; fails=$((fails+1))
    fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
L=media_lander.go
R=media_lander_run.go
S=media_server.go
mut "W1 onPark is always false (Parks)" TestMediaRestoreWaitParks $L \
  'in\.onPark\(c\.landed == before && transient > 0\)' 'in.onPark(transient < 0)'
mut "W2 a pass parks without a transient error (NotNetwork)" TestMediaRestoreWaitNotNetwork $L \
  'in\.onPark\(c\.landed == before && transient > 0\)' 'in.onPark(c.landed == before && transient >= 0)'
mut "W3 a landing does not clear the parked state (Clears)" TestMediaRestoreWaitClears $R \
  '\t\tif landedHere \{[^\n]*\n\t\t\tl\.setParkedLocked\(false\)\n\t\t\}\n' ''
mut "W4 writeProg writes RESTORE-WAITING with left 0 (Line)" TestMediaRestoreWaitLine $S \
  'if s\.restoring\.left > 0 && s\.restoring\.waiting \{' 'if s.restoring.waiting {'
mut "W5 the RESTORING line takes a fifth field (Line)" TestMediaRestoreWaitLine $S \
  '"RESTORING %d %d %d\\n", s\.restoring\.done, s\.restoring\.total, s\.restoring\.left\)' '"RESTORING %d %d %d %d\\n", s.restoring.done, s.restoring.total, s.restoring.left, 0)'
mut "W6 the runner does not wire onPark (BgLander)" TestMediaRestoreWaitBgLander $R \
  '\tin\.onPark = l\.onPark\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
