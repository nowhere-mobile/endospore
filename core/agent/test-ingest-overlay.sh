#!/usr/bin/env bash
# test-ingest-overlay.sh [--mutate] -- NWP-20261203-15: GET-INGEST reads an overlaid Documents/Imported through the
# overlay, only for the names on disk when kickMediad last asked mediad to start (size-checked), never the hidden
# .under path (the daemon's MLS level cannot reach /data/user/<N>), and logs every NONE's reason class. Runs the
# focused Go tests; --mutate applies each mutant to pristine copies of ingest_handoff.go and main.go (both restored
# on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure,
# never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp ingest_handoff.go "$W/ingest_handoff.go.orig" || exit 2
cp main.go "$W/main.go.orig" || exit 2
trap 'cp "$W/ingest_handoff.go.orig" ingest_handoff.go; cp "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestGetIngest|TestIngest|TestKickMediad'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
restore() {
  cp "$W/ingest_handoff.go.orig" ingest_handoff.go
  cp "$W/main.go.orig" main.go
}
# mutate <label> <file> <test that must fail> <python body acting on s>: apply to a pristine copy, require its --- FAIL
mutate() {
  local lbl="$1" file="$2" want="$3" body="$4" o
  restore
  if ! python3 -c "
s = open('$file').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('$file','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); restore; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL: $want"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL: $want; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  restore
}
echo "== mutations =="
mutate "M1: the snapshot-name filter is dropped" ingest_handoff.go TestGetIngestOverlayServesOnlySnapshotNames "
t = t.replace('if _, inSnap := snap[n]; inSnap {', 'if true {', 1)"
mutate "M2: the mapped branch reads the hidden path again" ingest_handoff.go TestGetIngestMappedNeverReadsUnder "
t = t.replace('_, mapped := ingestResolveDir(plain)\n\tdir := plain', 'dir, mapped := ingestResolveDir(plain)', 1)"
mutate "M3: ingestSnapshotStaged records while the dir is mapped" ingest_handoff.go TestIngestSnapshotSkippedWhenMapped "
t = t.replace('if _, mapped := ingestResolveDir(dir); mapped {\n\t\treturn\n\t}\n', '', 1)"
mutate "M4: the snapshot's uid key is ignored" ingest_handoff.go TestGetIngestSnapshotOtherUidIsNone "
t = t.replace('ingestSnapRec == nil || ingestSnapRec.uid != uid', 'ingestSnapRec == nil', 1)"
mutate "M5: the size check against the snapshot is dropped" ingest_handoff.go TestGetIngestOverlaySizeMismatchSkipped "
t = t.replace(' || st.Size() != snap[name]', '', 1)"
mutate "M6: the NONE reason line is not logged" ingest_handoff.go TestGetIngestNoneReasonLogged "
t = t.replace('\tingestLogf(\"[logind] ingest: user %s: NONE (%s) (NWP-20261203-15)\\\\n\", userID, reason)\n', '', 1)"
mutate "M7: kickMediad no longer takes the snapshot" main.go TestKickMediadSnapshotsBeforeStart "
import re
t = re.sub(r'\n\tingestSnapshotStaged\(uid\) //[^\n]*', '', t, count=1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "7 mutants convicted"
