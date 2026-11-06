#!/usr/bin/env bash
# test-media-writeback-copy.sh [--mutate] -- NWP-20261115-03: copyFile (mediafs.go) copies a mediad write-back seed
# into a .nwseed-* temp in dst's own directory and renames only a complete copy over dst, so a copy cut short
# (ENOSPC) leaves no cut file in .under for the next seal to record over the stored one. --mutate applies each
# mutant to a pristine copy of mediafs.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not
# apply, or does not compile, is a failure, never a conviction. No mutant needs FUSE: a skip counts as SURVIVED.
#   M1 the rename runs before the copy's error is checked (a cut copy lands at dst)
#   M2 the failure path keeps its temp
#   M3 the temp is not chmodded (dst keeps CreateTemp's 0600)
#   M4 copyFile writes straight into dst again (the pre-change shape)
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp mediafs.go "$W/mediafs.orig" || exit 2
trap 'cp "$W/mediafs.orig" mediafs.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestCopyFile|TestMaterializeCutCopy|TestMaterializePinnedMakesLocalAndEssential|TestMaterializeRestoresRecordedMTime|TestOverlayWriteOpenStubMaterializes|TestOverlayAppendKeepsDeferredBytes|TestOverlayTruncateOnStubStillMaterializes|TestEveryGoroutineGoesThroughGoSafe'
out=$(go test -count=1 -v -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
skipped=$(grep -- '--- SKIP' <<<"$out" || true)
[ -z "$skipped" ] || echo "NOTE: skipped here (no usable FUSE; the CI runner must not skip them): $skipped"
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <run-regex> <old> <new>: replace the first <old> in a pristine mediafs.go
mutate() {
  local lbl="$1" run="$2" old="$3" new="$4" res
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
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
COPY_OK='	if _, err := copyFileData(tmp, in); err != nil {
		tmp.Close()
		return err
	}'
COPY_M1='	_, cerr := copyFileData(tmp, in)
	tmp.Close()
	os.Rename(tmpName, dst)
	if cerr != nil {
		return cerr
	}'
REMOVE_OK='	defer os.Remove(tmpName) // a no-op once the rename has landed
'
CHMOD_OK='	if err := os.Chmod(tmpName, mode); err != nil {
		return err
	}
'
BODY_OK='	tmp, err := os.CreateTemp(filepath.Dir(dst), ".nwseed-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // a no-op once the rename has landed
	if _, err := copyFileData(tmp, in); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return err
	}
	return os.Rename(tmpName, dst)'
BODY_M4='	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := copyFileData(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()'
mutate "M1 the rename runs before the copy's error is checked" "TestCopyFileCutCopyLeavesDstAlone" "$COPY_OK" "$COPY_M1"
mutate "M2 the failure path keeps its temp" "TestCopyFileFailureLeavesNoFile|TestCopyFileCutCopyLeavesDstAlone" "$REMOVE_OK" ""
mutate "M3 the temp is not chmodded" "TestCopyFileLands" "$CHMOD_OK" ""
mutate "M4 copyFile writes straight into dst (pre-change)" "TestMaterializeCutCopyKeepsTheStoredFile" "$BODY_OK" "$BODY_M4"
cp "$W/mediafs.orig" mediafs.go
if [ "$FAILS" -ne 0 ]; then echo "== $FAILS mutation(s) not convicted"; exit 1; fi
echo "== all mutations convicted"
