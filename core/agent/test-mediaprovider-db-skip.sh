#!/usr/bin/env bash
# test-mediaprovider-db-skip.sh [--mutate] -- NWP-20261202-02 (docs/product-decisions.md, 2026-11-10, option A):
# MediaProvider's external.db and internal.db (with -wal, -shm, -journal, both module names) are skipped by every
# seal walker and priced for the shrink guard, and untarFrom leaves an older head's copies unwritten without
# withholding the restore receipt. Runs the focused Go tests (with the Play download ones: same walkers); --mutate
# applies each mutant to a pristine copy of the source (restored on exit) and requires a real `--- FAIL`: a mutant
# that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES="media_server.go incremental_seal.go main.go seal_delta_walk.go"
restore() {
  local f
  for f in $FILES; do [ -f "$W/$f.orig" ] && cp "$W/$f.orig" "$f"; done
  return 0
}
for f in $FILES; do cp "$f" "$W/$f.orig" || exit 2; done
trap 'restore; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='MediaProviderDB|PlayDownload'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
N=0
# mutate <label> <file> <test that must fail> <python body acting on s/t>
mutate() {
  local lbl="$1" file="$2" want="$3" body="$4" o
  N=$((N+1))
  restore
  if ! python3 -c "
import re
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
mutate "M1: the predicate drops -wal" media_server.go TestMediaProviderDBRelPredicate "
t = t.replace('\"external.db-wal\": true, ', '', 1)"
mutate "M2: the predicate accepts any prefix" media_server.go TestMediaProviderDBRelPredicate "
t = t.replace('return len(parts) == 3 && mediaProviderPkgs[parts[0]]', 'if len(parts) > 3 {\n\t\tparts = parts[len(parts)-3:]\n\t}\n\treturn len(parts) == 3 && mediaProviderPkgs[parts[0]]', 1)"
mutate "M3: walkChunks' skip is removed" incremental_seal.go TestMediaProviderDBSkippedByWalkChunks "
t = t.replace('if info.Mode().IsRegular() && isMediaProviderDBRel(filepath.ToSlash(rel)) {', 'if false && isMediaProviderDBRel(filepath.ToSlash(rel)) {', 1)"
mutate "M4: walkChunks' skip is not priced" incremental_seal.go TestMediaProviderDBSkippedByWalkChunks "
t = re.sub(r'(isMediaProviderDBRel\(filepath\.ToSlash\(rel\)\) \{.*?)\t\t\tdropped \+= info\.Size\(\)\n', r'\1', t, count=1, flags=re.S)"
mutate "M5: tarDirTo's skip is removed" main.go TestMediaProviderDBSkippedByTarDirTo "
t = t.replace('if info.Mode().IsRegular() && isMediaProviderDBRel(filepath.ToSlash(rel)) {', 'if false && isMediaProviderDBRel(filepath.ToSlash(rel)) {', 1)"
mutate "M6: untarFrom's skip is removed" main.go TestMediaProviderDBNotWrittenByUntarFrom "
t = t.replace('if isMediaProviderDBRel(filepath.ToSlash(hdr.Name)) {', 'if false && isMediaProviderDBRel(filepath.ToSlash(hdr.Name)) {', 1)"
mutate "M7: untarFrom counts the entry in skipped" main.go TestMediaProviderDBNotWrittenByUntarFrom "
t = t.replace('mpDBLeft++ // NWP-20261202-02', 'skipped++ // NWP-20261202-02', 1)"
mutate "M8: sealDeltaWalk's skip is removed" seal_delta_walk.go TestMediaProviderDBNotCountedBySealDeltaWalk "
t = t.replace('if isMediaProviderDBRel(rel) {', 'if false && isMediaProviderDBRel(rel) {', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "$N mutants convicted"
