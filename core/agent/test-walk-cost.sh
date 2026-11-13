#!/usr/bin/env bash
# test-walk-cost.sh [--mutate] -- runs walk_cost_test.go (NWP-20261202-15, h49 #4 step 2: every incremental push
# logs one `walk cost:` line after the group-cache line -- the groups the walk read and their time, the rest of the
# walk, the process CPU and the /proc/pressure stall deltas; an unknown value prints n/a, never 0). --mutate re-runs it
# against copies of incremental_seal.go, walk_cost.go and main.go with each piece broken in turn, injected with
# `go test -overlay`, so the source tree is never edited. Mutants: m1 gRead++ removed, m2 beginWalk's gRead reset
# dropped, m3 the cpu delta prints `after` only, m4 the PSI parser reads `some` for both lines, m5 unknown printed as
# 0, m6 the main.go Printf removed. Each mutant must be CONVICTED by a real `--- FAIL` of the test it names; one that
# does not apply, does not compile, fails another test only, or dies without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestWalkCost_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <test that must fail> <file> <python-regex pattern> <replacement>
  local label="$1" want="$2" src="$3" m ov out
  m=$(mktemp -p "$W" mut.XXXXXX.go) || exit 2
  ov=$(mktemp -p "$W" overlay.XXXXXX.json) || exit 2
  python3 - "$src" "$m" "${@:4}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst=sys.argv[1:3]
rest=sys.argv[3:]
s=open(src).read()
for pat,rep in zip(rest[0::2],rest[1::2]):
    s,c=re.subn(pat,lambda _m:rep,s,flags=re.S)
    if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run 'TestWalkCost_' . 2>&1)
  if grep -q -- "--- FAIL: $want " <<<"$out"; then
    echo "  convicted $label: $(grep -m1 -- "--- FAIL: $want " <<<"$out")"
  elif grep -q -- '--- FAIL' <<<"$out"; then
    echo "  WRONG-TEST $label -- $want did not fail: $(grep -m1 -- '--- FAIL' <<<"$out")"; fails=$((fails+1))
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "m1 gRead++ removed" TestWalkCost_GroupsRead incremental_seal.go \
  '\n\tsc\.gRead\+\+\n' $'\n'
mut "m2 beginWalk's gRead reset dropped" TestWalkCost_ReadResetPerWalk incremental_seal.go \
  '\n\tsc\.gRead, sc\.gReadNanos = 0, 0\n' $'\n'
mut "m3 the cpu delta prints after only" TestWalkCost_Delta walk_cost.go \
  'walkCostSub\(before\.user, after\.user\), walkCostSub\(before\.sys, after\.sys\)' 'after.user, after.sys'
mut "m4 the PSI parser reads some for both lines" TestWalkCost_PSISomeVsFull walk_cost.go \
  'walkCostPSITotal\(b, "full"\)' 'walkCostPSITotal(b, "some")'
mut "m5 unknown printed as 0" TestWalkCost_Unknown walk_cost.go \
  'return "n/a"' 'return "0s"'
mut "m6 the main.go Printf removed" TestWalkCost_OneLinePerPush main.go \
  'fmt\.Printf\("push: profile %s %s\\n", logProfile\(profile\), walkCostLine\(' \
  '_ = fmt.Sprintf("push: profile %s %s\n", logProfile(profile), walkCostLine('
[ "$fails" -eq 0 ] && echo "== all 6 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
