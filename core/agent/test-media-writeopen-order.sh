#!/usr/bin/env bash
# test-media-writeopen-order.sh [--mutate] -- NWP-20261127-04: a write open over an on-demand stub tombstones it only
# after the real file opened (openForWrite, mediafs.go), and a failed open after a seed removes the seed copy, so a
# failed write open keeps the stub. mediaRoot.Create tombstones a live stub only after its loopback create landed; the
# kernel never reaches that arm (an O_CREAT over a live stub arrives as OPEN), so a SOURCE PIN holds its order.
# --mutate applies each Go mutant to a pristine copy of mediafs.go (restored on exit) and requires a real `--- FAIL`:
# a mutant that does not apply, or does not compile, is a failure, never a conviction. M1-M3 need FUSE: where the
# tests skip they are NOT RUN. C1-C2 mutate a copy in the temp root and must make the source pin fail.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp mediafs.go "$W/mediafs.orig" || exit 2
trap 'cp "$W/mediafs.orig" mediafs.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

# create_pin <file>: mediaRoot.Create must call the loopback before markDeleted(rel), and markDeleted must sit
# directly under an `if` naming both errno and live.
create_pin() {
  local body call del guard
  body=$(awk '/^func \(r \*mediaRoot\) Create\(/{p=1} p{print} p&&/^}/{exit}' "$1")
  [ -n "$body" ] || return 1
  call=$(grep -n 'r\.LoopbackNode\.Create(' <<<"$body" | head -1 | cut -d: -f1)
  del=$(grep -n 'markDeleted(rel)' <<<"$body" | head -1 | cut -d: -f1)
  [ -n "$call" ] && [ -n "$del" ] || return 1
  [ "$call" -lt "$del" ] || return 1
  guard=$(sed -n "$((del-1))p" <<<"$body")
  grep -Eq '^[[:space:]]*if .*\berrno\b.*\blive\b|^[[:space:]]*if .*\blive\b.*\berrno\b' <<<"$guard"
}
if ! create_pin mediafs.go; then
  echo "FAIL: mediaRoot.Create must tombstone a live stub only after its loopback create returned 0 (source pin)"
  exit 1
fi
echo "ok: the Create source pin holds"

RUN="^(TestOverlayWriteOpenFailedOverStubKeepsIt|TestOverlayRdwrOpenFailedOverStubKeepsIt|TestOverlayCreatFlagOverStubKeepsIt|TestOverlayWriteOpenOverStubSupersedes|TestEveryGoroutineGoesThroughGoSafe)$"
out=$(go test -count=1 -v -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
skipped=$(grep -- '--- SKIP' <<<"$out" || true)
[ -z "$skipped" ] || echo "NOTE: skipped here (no usable FUSE; the CI runner must not skip them): $skipped"
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
NOTRUN=0
CONVICTED=0
# apply_once <src> <dst> <old> <new>: write <src> to <dst> with the single occurrence of <old> replaced; fails when
# <old> is absent or occurs more than once.
apply_once() {
  local src="$1" dst="$2" old="$3" new="$4"
  SRC="$src" DST="$dst" OLD="$old" NEW="$new" python3 -c "
import os
s = open(os.environ['SRC']).read()
if s.count(os.environ['OLD']) != 1: raise SystemExit('mutant did not apply')
open(os.environ['DST'],'w').write(s.replace(os.environ['OLD'], os.environ['NEW'], 1))"
}
# mutate <label> <run-regex> <needs-fuse: 1|0> <old> <new>: replace <old> in a pristine mediafs.go and run the tests
mutate() {
  local lbl="$1" run="$2" fuse="$3" old="$4" new="$5" res
  cp "$W/mediafs.orig" mediafs.go
  if ! apply_once "$W/mediafs.orig" mediafs.go "$old" "$new"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -v -run "$run" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"; CONVICTED=$((CONVICTED+1))
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  elif [ "$fuse" = 1 ] && grep -q -- '--- SKIP' <<<"$res"; then
    echo "  NOT RUN   $lbl -- no usable FUSE here; the CI runner convicts it"; NOTRUN=$((NOTRUN+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
# pinmut <label> <old> <new>: replace <old> in a pristine copy in the temp root; the Create source pin must fail on it
pinmut() {
  local lbl="$1" old="$2" new="$3"
  if ! apply_once "$W/mediafs.orig" "$W/pin.go" "$old" "$new"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  if create_pin "$W/pin.go"; then echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1))
  else echo "  convicted $lbl"; CONVICTED=$((CONVICTED+1)); fi
}
OPEN_OK='	fd, err := writeOpenFile('
OPEN_M1='	f.srv.markDeleted(f.rel)
	fd, err := writeOpenFile('
SEED_OK='		seeded = true'
SEED_M2='		seeded = true
		f.srv.markDeleted(f.rel)'
CREATE_OK='	live := r.deferSet[name] && !r.srv.isDeleted(rel)
	inode, fh, fuseFlags, errno := r.LoopbackNode.Create(ctx, name, flags, mode, out)
	if live && errno == 0 {
		r.srv.markDeleted(rel)
		dlog("mediad: CREATE over deferred %q (stub superseded by write-back)", rel)
	}'
CREATE_C1='	live := r.deferSet[name] && !r.srv.isDeleted(rel)
	if live {
		r.srv.markDeleted(rel)
		dlog("mediad: CREATE over deferred %q (stub superseded by write-back)", rel)
	}
	inode, fh, fuseFlags, errno := r.LoopbackNode.Create(ctx, name, flags, mode, out)'
GUARD_OK='	if live && errno == 0 {
		r.srv.markDeleted(rel)
		dlog("mediad: CREATE over'
GUARD_C2='	if live {
		r.srv.markDeleted(rel)
		dlog("mediad: CREATE over'
mutate "M1 the non-seeding tombstone back above the open" "^(TestOverlayWriteOpenFailedOverStubKeepsIt|TestOverlayCreatFlagOverStubKeepsIt)$" 1 "$OPEN_OK" "$OPEN_M1"
mutate "M2 the seeding tombstone above the open" "^TestOverlayRdwrOpenFailedOverStubKeepsIt$" 1 "$SEED_OK" "$SEED_M2"
mutate "M3 a failed open keeps the seed copy" "^TestOverlayRdwrOpenFailedOverStubKeepsIt$" 1 '			os.Remove(underPath) // this call made the seed copy' '			_ = underPath // this call made the seed copy'
cp "$W/mediafs.orig" mediafs.go
pinmut "C1 Create tombstones before the loopback create" "$CREATE_OK" "$CREATE_C1"
pinmut "C2 Create tombstones whatever the loopback returns" "$GUARD_OK" "$GUARD_C2"
if [ "$FAILS" -ne 0 ]; then echo "== $FAILS mutation(s) not convicted"; exit 1; fi
if [ "$NOTRUN" -ne 0 ]; then echo "== $CONVICTED convicted, $NOTRUN NOT RUN (no FUSE)"; else echo "== all mutations convicted"; fi
