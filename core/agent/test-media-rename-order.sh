#!/usr/bin/env bash
# test-media-rename-order.sh [--mutate] -- NWP-20261110-09: a rename over an on-demand stub tombstones it only after
# the loopback rename landed (supersedeAfter, mediafs.go), so a failed rename keeps the stub. --mutate applies each
# mutant to a pristine copy of mediafs.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not
# apply, or does not compile, is a failure, never a conviction. M3 needs FUSE: where F1 skips it is NOT RUN.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp mediafs.go "$W/mediafs.orig" || exit 2
trap 'cp "$W/mediafs.orig" mediafs.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestSupersedeAfter|TestOverlayRename|TestEveryGoroutineGoesThroughGoSafe"
out=$(go test -count=1 -v -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
skipped=$(grep -- '--- SKIP' <<<"$out" || true)
[ -z "$skipped" ] || echo "NOTE: skipped here (no usable FUSE; the CI runner must not skip them): $skipped"
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
NOTRUN=0
CONVICTED=0
# mutate <label> <run-regex> <needs-fuse: 1|0> <old> <new>: replace the first <old> in a pristine mediafs.go
mutate() {
  local lbl="$1" run="$2" fuse="$3" old="$4" new="$5" res
  cp "$W/mediafs.orig" mediafs.go
  if ! OLD="$old" NEW="$new" python3 -c "
import os
s = open('mediafs.go').read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open('mediafs.go','w').write(t)"; then
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
HELPER_OK='	errno := op()
	if errno == 0 && live {
		srv.markDeleted(rel)
		dlog("mediad: RENAME over deferred %q (stub superseded by write-back)", rel)
	}
	return errno'
HELPER_M1='	if live {
		srv.markDeleted(rel)
		dlog("mediad: RENAME over deferred %q (stub superseded by write-back)", rel)
	}
	return op()'
CALL_OK='	live := nr.deferSet[newName] && !nr.srv.isDeleted(rel)
	return supersedeAfter(nr.srv, rel, live, func() syscall.Errno {
		return r.LoopbackNode.Rename(ctx, name, newParent, newName, flags)
	})'
CALL_M3='	if nr.deferSet[newName] && !nr.srv.isDeleted(rel) {
		nr.srv.markDeleted(rel)
		dlog("mediad: RENAME over deferred %q (stub superseded by write-back)", rel)
	}
	return r.LoopbackNode.Rename(ctx, name, newParent, newName, flags)'
mutate "M1 the helper tombstones before op" "TestSupersedeAfter" 0 "$HELPER_OK" "$HELPER_M1"
mutate "M2 the helper tombstones whatever op returns" "TestSupersedeAfter" 0 'if errno == 0 && live {' 'if live {'
mutate "M3 Rename keeps the inline pre-op tombstone" "TestOverlayRenameFailedOverStub" 1 "$CALL_OK" "$CALL_M3"
cp "$W/mediafs.orig" mediafs.go
if [ "$FAILS" -ne 0 ]; then echo "== $FAILS mutation(s) not convicted"; exit 1; fi
if [ "$NOTRUN" -ne 0 ]; then echo "== $CONVICTED convicted, $NOTRUN NOT RUN (no FUSE)"; else echo "== all mutations convicted"; fi
