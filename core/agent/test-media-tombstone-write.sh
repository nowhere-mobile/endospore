#!/usr/bin/env bash
# test-media-tombstone-write.sh [--mutate] -- NWP-20261127-06: an unlink of an on-demand stub whose tombstone cannot
# be appended to <cacheDir>/.deleted fails with the stub kept (mediaRoot.Unlink, mediafs.go); markDeleted reports
# the failed append, repairs a torn last line and evicts the cache only after the append landed (media_server.go).
# --mutate applies each mutant to pristine copies of both files (restored on exit) and requires a real `--- FAIL`:
# a mutant that does not apply, or does not compile, is a failure, never a conviction. M3 and M5 need FUSE: where
# the overlay test skips they are NOT RUN.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp media_server.go "$W/media_server.orig" || exit 2
cp mediafs.go "$W/mediafs.orig" || exit 2
trap 'cp "$W/media_server.orig" media_server.go; cp "$W/mediafs.orig" mediafs.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestMarkDeleted|TestOverlayUnlink|TestSealDropsTombstonedDeferred|TestEveryGoroutineGoesThroughGoSafe"
out=$(go test -count=1 -v -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
skipped=$(grep -- '--- SKIP' <<<"$out" || true)
[ -z "$skipped" ] || echo "NOTE: skipped here (no usable FUSE; the CI runner must not skip them): $skipped"
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
NOTRUN=0
CONVICTED=0
# mutate <label> <file> <run-regex> <needs-fuse: 1|0> <old> <new>: replace the first <old> in a pristine <file>
mutate() {
  local lbl="$1" file="$2" run="$3" fuse="$4" old="$5" new="$6" res
  cp "$W/media_server.orig" media_server.go
  cp "$W/mediafs.orig" mediafs.go
  if ! F="$file" OLD="$old" NEW="$new" python3 -c "
import os
f = os.environ['F']
s = open(f).read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)"; then
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
APPEND_OK='	if err := s.appendTombstone(rel); err != nil {
		var en syscall.Errno
		if errors.As(err, &en) && en != 0 {
			return en
		}
		return syscall.EIO
	}
	if d, ok := s.attr(rel); ok {
		key := cacheKey(d)
		for _, suf := range []string{"", ".part", ".have"} {
			os.Remove(filepath.Join(s.cacheDir, key+suf))
		}
	}'
APPEND_M4='	if d, ok := s.attr(rel); ok {
		key := cacheKey(d)
		for _, suf := range []string{"", ".part", ".have"} {
			os.Remove(filepath.Join(s.cacheDir, key+suf))
		}
	}
	if err := s.appendTombstone(rel); err != nil {
		var en syscall.Errno
		if errors.As(err, &en) && en != 0 {
			return en
		}
		return syscall.EIO
	}'
mutate "M1 the append error dropped" media_server.go "TestMarkDeletedReportsAFailedAppend" 0 \
  'if err := s.appendTombstone(rel); err != nil {' 'if err := s.appendTombstone(rel); false && err != nil {'
mutate "M2 the torn-line repair dropped" media_server.go "TestMarkDeletedRepairsATornLastLine" 0 \
  "err == nil && b[0] != '\\n' {" "err == nil && false && b[0] != '\\n' {"
mutate "M3 Unlink ignores the error again" mediafs.go "TestOverlayUnlinkKeepsTheStubWhenItsTombstoneFails" 1 \
  'if err := r.srv.markDeleted(rel); err != nil {' 'if err := r.srv.markDeleted(rel); false && err != nil {'
mutate "M4 the cache evicted before the append" media_server.go "TestMarkDeletedReportsAFailedAppend" 0 \
  "$APPEND_OK" "$APPEND_M4"
mutate "M5 Unlink keeps the RAM tombstone" mediafs.go "TestOverlayUnlinkKeepsTheStubWhenItsTombstoneFails" 1 \
  '			r.srv.unmarkDeleted(rel)
' ''
cp "$W/media_server.orig" media_server.go
cp "$W/mediafs.orig" mediafs.go
if [ "$FAILS" -ne 0 ]; then echo "== $FAILS mutation(s) not convicted"; exit 1; fi
if [ "$NOTRUN" -ne 0 ]; then echo "== $CONVICTED convicted, $NOTRUN NOT RUN (no FUSE)"; else echo "== all mutations convicted"; fi
