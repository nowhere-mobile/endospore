#!/usr/bin/env bash
# test-cap-read-cache.sh [--mutate] -- NWP-20261101-17: capReadCache drops expired read caps (capReadPutLocked's sweep),
# keeps live ones, sweeps at most once per capReadSweepEvery, and both store sites (capReadURL, prefetchReadCaps) go
# through it. Runs the focused Go tests; --mutate applies each mutant to a pristine copy of main.go (restored on exit)
# and requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestCapReadCache"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" body="$2" o
  cp "$W/main.go.orig" main.go
  if ! python3 -c "
s = open('main.go').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('main.go','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); cp "$W/main.go.orig" main.go; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  cp "$W/main.go.orig" main.go
}
echo "== mutations =="
mutate "K1: the sweep loop is removed" "
t = s.replace('\t\t\tif !old.exp.After(now) {\n\t\t\t\tdelete(capReadCache, k)\n\t\t\t}\n', '\t\t\t_, _ = k, old\n', 1)"
mutate "K2: the expiry comparison is inverted (live entries deleted)" "
t = s.replace('if !old.exp.After(now) {', 'if old.exp.After(now) {', 1)"
mutate "K3: prefetchReadCaps stores straight into the map" "
t = s.replace('capReadPutLocked(ref, capEntry{url: u, exp: exp}, now)', 'capReadCache[ref] = capEntry{url: u, exp: exp}', 1)"
mutate "K4: capReadURL stores straight into the map" "
t = s.replace('capReadPutLocked(key, capEntry{url: u, exp: now.Add(30 * time.Second)}, now)', 'capReadCache[key] = capEntry{url: u, exp: now.Add(30 * time.Second)}', 1)"
mutate "K5: the throttle is removed (every put sweeps)" "
t = s.replace('if now.Sub(capReadSweptAt) >= capReadSweepEvery {', 'if true {', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "5 mutants convicted"
