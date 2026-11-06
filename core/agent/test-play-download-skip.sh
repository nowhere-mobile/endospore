#!/usr/bin/env bash
# test-play-download-skip.sh [--mutate] -- NWP-20261102-01 (Q076): Play's download cache
# (com.android.vending/files/phonesky-download-service) is skipped by every seal walker and priced for the shrink guard,
# while an old head's deferred records there follow the existing fetched-then-gone carry rule (carried until the sign-in
# heal handled them, never dropped unfetched). Runs the focused Go tests; --mutate applies each mutant to a pristine
# copy of the source (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does not
# compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES="media_server.go incremental_seal.go main.go"
restore() {
  local f
  for f in $FILES; do [ -f "$W/$f.orig" ] && cp "$W/$f.orig" "$f"; done
  return 0
}
for f in $FILES; do cp "$f" "$W/$f.orig" || exit 2; done
trap 'restore; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='PlayDownload'
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
mutate "P1: walkChunks' skip is removed" incremental_seal.go TestPlayDownloadSkippedByWalkChunks "
t = t.replace('if isPlayDownloadPath(rel) {', 'if false && isPlayDownloadPath(rel) {', 1)"
mutate "P2: walkChunks' dropped-bytes count is removed" incremental_seal.go TestPlayDownloadSkippedByWalkChunks "
t = re.sub(r'(isPlayDownloadPath\(rel\) \{.*?)dropped \+= subtreeBytes\(p\)\n', r'\1', t, count=1, flags=re.S)"
mutate "P3: tarDirTo's skip is removed" main.go TestPlayDownloadSkippedByTarDirTo "
t = t.replace('info.IsDir() && isPlayDownloadPath(rel)', 'false && isPlayDownloadPath(rel)', 1)"
mutate "P3b: tarDirTo's dropped-bytes count is removed" main.go TestPlayDownloadSkippedByTarDirTo "
t = t.replace('\t\t\tdropped += subtreeBytes(p) // priced for the shrink guard, same as walkChunks\n', '', 1)"
mutate "P4: the predicate also matches a longer sibling name" media_server.go TestIsPlayDownloadPath "
t = t.replace('strings.HasPrefix(rel, playDownloadRel+\"/\")', 'strings.HasPrefix(rel, playDownloadRel)', 1)"
mutate "P5: the carry's healHandled arm is removed (a fetched record is still carried)" main.go TestPlayDownloadDeferredCarriedUntilHealed "
t = t.replace('if healHandled[rel] {', 'if false && healHandled[rel] {', 1)"
mutate "P6: an unconditional isPlayDownloadPath drop is added to the carry (an unfetched record is dropped)" main.go TestPlayDownloadDeferredCarriedUntilHealed "
t = t.replace('if healHandled[rel] {', 'if isPlayDownloadPath(rel) {\n\t\t\t\tcontinue\n\t\t\t}\n\t\t\tif healHandled[rel] {', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "$N mutants convicted"
