#!/usr/bin/env bash
# test-ingest-nofollow.sh [--mutate] -- NWP-20261101-18: GET-INGEST serves only regular files it opened itself
# (O_NOFOLLOW, O_NONBLOCK, bounded by the bytes read) from a staging dir with no linked component. Runs the focused Go
# tests; --mutate applies each mutant to a pristine copy of ingest_handoff.go (restored on exit) and requires a real
# `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp ingest_handoff.go "$W/ingest_handoff.go.orig" || exit 2
trap 'cp "$W/ingest_handoff.go.orig" ingest_handoff.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestIngestNoFollow|TestGetIngest|TestIngest'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <test that must fail> <python body acting on s>: apply to a pristine copy, require its --- FAIL
mutate() {
  local lbl="$1" want="$2" body="$3" o
  cp "$W/ingest_handoff.go.orig" ingest_handoff.go
  if ! python3 -c "
s = open('ingest_handoff.go').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('ingest_handoff.go','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); cp "$W/ingest_handoff.go.orig" ingest_handoff.go; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL: $want"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL: $want; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  cp "$W/ingest_handoff.go.orig" ingest_handoff.go
}
echo "== mutations =="
mutate "N1: ingestReadStaged's Lstat link check, O_NOFOLLOW and SameFile check are removed" TestIngestNoFollow_ReadStagedRefusesLink "
t = t.replace('err != nil || !lst.Mode().IsRegular() {', 'err != nil || lst == nil {', 1)
t = t.replace('os.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK', 'os.O_RDONLY|unix.O_NONBLOCK', 1)
t = t.replace(' || !os.SameFile(lst, fst)', '', 1)"
mutate "N2: the staging-dir component check is removed" TestIngestNoFollow_DirLink "
t = t.replace('if !ingestStagingDirOK(dir, mapped) {', 'if false {', 1)"
mutate "N3: O_NONBLOCK and both regular-file checks in ingestReadStaged are removed" TestIngestNoFollow_ReadStagedFIFO "
t = t.replace('err != nil || !lst.Mode().IsRegular() {', 'err != nil || lst == nil {', 1)
t = t.replace('os.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK', 'os.O_RDONLY|unix.O_NOFOLLOW', 1)
t = t.replace('err != nil || !fst.Mode().IsRegular() || !os.SameFile(lst, fst) {', 'err != nil || fst == nil {', 1)"
mutate "N4: the bytes-read comparison against max is removed" TestIngestNoFollow_SizeOnOpenedFile "
t = t.replace(' || int64(len(b)) > max {', ' {', 1)"
mutate "N5: ingestList's IsRegular filter is reverted to IsDir" TestIngestNoFollow_ListSkipsNonRegular "
t = t.replace('!e.Type().IsRegular() ||', 'e.IsDir() ||', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "5 mutants convicted"
