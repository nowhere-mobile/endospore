#!/usr/bin/env bash
# test-rotate-seal-busy.sh [--mutate] -- runs rotate_seal_busy_test.go (NWP-20261113-04): a live session's ROTATE answers
# BUSY while a seal is running or queued, and a rotation holds the periodic seal off. --mutate applies each mutant to a
# COPY of the package under one temp root (the tree is never edited) and requires a real `--- FAIL`; a mutant that fails
# to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestRotateSealBusy' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <literal old text> <literal new text>: first occurrence in main.go, in a fresh package copy
  local label="$1" d res mrc
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$d/pkg" || { echo "  BROKEN    $label -- the package copy failed"; fails=$((fails+1)); return; }
  python3 - "$d/pkg/main.go" "$2" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p,old,new=sys.argv[1:4]
s=open(p).read()
if old not in s: sys.exit(1)
open(p,'w').write(s.replace(old,new,1))
PY
  res=$(cd "$d/pkg" && "${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$d"
}
mut "M1 handleRotate drops the seal guard" 'if !beginRotate(time.Now()) {' 'if false {'
mut "M2 beginRotate ignores a queued periodic" 'if anySealRunningLocked(now) || sealRunKind != "" {' 'if anySealRunningLocked(now) {'
mut "M3 the announce ignores rotateInFlight" $'if rotateInFlight {\n\t\tpendingReapMu.Unlock()' $'if false {\n\t\tpendingReapMu.Unlock()'
mut "M4 syncLoop's defer ignores rotateInFlight" 'if reason == "" && rotateInFlight {' 'if false {'
mut "M5 the BUSY line prints the raw uid field" 'nothing changed (NWP-20261113-04)\n", rotateLogUID(su))' 'nothing changed (NWP-20261113-04)\n", su)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
