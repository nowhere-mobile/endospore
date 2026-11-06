#!/usr/bin/env bash
# test-export-fetch-skipped.sh [--mutate] -- NWP-20261110-19: exportFetchMedia refuses a restore that skipped
# entries (untarFrom's count), on the CDC and the legacy single-tar arm, and before the deferred loop. --mutate
# applies each mutant to a pristine copy of export_media.go (restored on exit) and requires a real `--- FAIL`: a
# mutant that does not apply, or does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp export_media.go "$W/em.orig" || exit 2
trap 'cp "$W/em.orig" export_media.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="TestExportFetchSkipped|TestExportMedia|TestExportRekey|TestEveryGoroutineGoesThroughGoSafe"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new> [<old2> <new2>]: replace the first <old> (then <old2>) in a pristine export_media.go,
# require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" old2="${4:-}" new2="${5:-}" res
  cp "$W/em.orig" export_media.go
  if ! OLD="$old" NEW="$new" OLD2="$old2" NEW2="$new2" python3 -c "
import os
f = 'export_media.go'
s = open(f).read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
if os.environ['OLD2']:
    u = t.replace(os.environ['OLD2'], os.environ['NEW2'], 1)
    if u == t: raise SystemExit('second edit did not apply')
    t = u
open(f,'w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "TestExportFetchSkipped" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "M1 the CDC arm's count ignored" 'n := cdcRestore(base, dk, m, destDir); n > 0' 'n := cdcRestore(base, dk, m, destDir); n < 0'
mutate "M2 the legacy arm back to untarTo" 'if n := untarFrom(destDir, bytes.NewReader(pt)); n > 0 {' 'untarTo(destDir, pt)
		if n := int(bytes.NewReader(pt).Size()) * 0; n > 0 {'
mutate "M3 the CDC check after the deferred loop" '	if n := cdcRestore(base, dk, m, destDir); n > 0 {
		return fmt.Errorf("export restore skipped %d entr(y/ies)", n)
	}
' '	n := cdcRestore(base, dk, m, destDir)
' '	}
	return nil
}' '	}
	if n > 0 {
		return fmt.Errorf("export restore skipped %d entr(y/ies)", n)
	}
	return nil
}'
cp "$W/em.orig" export_media.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
