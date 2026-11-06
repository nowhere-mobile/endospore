#!/usr/bin/env bash
# test-media-sync-nolink.sh [--mutate] -- NWP-20261110-05: the mid-session media sync (writeMaterialized,
# mkdirOwnedBelow) follows no link below the scope root. --mutate applies each mutant to a pristine copy of
# media_span.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or does not
# compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp media_span.go "$W/ms.orig" || exit 2
trap 'cp "$W/ms.orig" media_span.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestMediaSyncNoLink|TestMaterialize|TestAppExt|TestMediaSync|TestNoLogPrintsAProfileNameOutsideQuotes|TestEveryGoroutineGoesThroughGoSafe"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new> <all>: replace <old> (the first, or every one when <all> is 1) in a pristine copy of
# media_span.go and require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" all="${4:-0}" res
  cp "$W/ms.orig" media_span.go
  if ! OLD="$old" NEW="$new" ALL="$all" python3 -c "
import os
s = open('media_span.go').read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], -1 if os.environ['ALL'] == '1' else 1)
if t == s: raise SystemExit('mutant did not apply')
open('media_span.go','w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "TestMediaSyncNoLink" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "M1 writeMaterialized's noLinkBelow calls removed" 'if err := noLinkBelow(root, dir); err != nil {' 'if err := error(nil); err != nil {' 1
mutate "M2 noLinkBelow uses os.Stat" 'st, err := os.Lstat(p)' 'st, err := os.Stat(p)'
mutate "M3 mkdirOwnedBelow back to os.Stat" 'serr := os.Lstat(p); serr == nil' 'serr := os.Stat(p); serr == nil'
mutate "M4 noLinkBelow stops before the last component" 'for _, seg := range strings.Split(rel, string(filepath.Separator)) {
		p = filepath.Join(p, seg)
		st, err := os.Lstat(p)' 'segs := strings.Split(rel, string(filepath.Separator))
	for _, seg := range segs[:len(segs)-1] {
		p = filepath.Join(p, seg)
		st, err := os.Lstat(p)'
cp "$W/ms.orig" media_span.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
