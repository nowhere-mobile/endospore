#!/usr/bin/env bash
# test-media-after-gate-seal.sh [--mutate] -- runs media_after_gate_seal_test.go (NWP-20261128-03, backlog "A 179-second
# login, 95% of it bulk media restored INLINE before the gate opens", Q106 slice S3: the #media seal under an after-gate
# split, docs/media-after-gate.md §5). --mutate re-runs it against a COPY of the package with one rule broken in turn.
# Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'MediaAfterGateSeal' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
mut() {
  local label="$1" f="$2" res rc
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 aftergateActive reads an unreadable marker as absent" media_after_gate.go \
  'if err != nil \{\n\t\treturn true' 'if err != nil {\n\t\treturn false'
mut "M2 the restored-set filter is removed" main.go \
  'restoredEss = essWithout\(restoredM\.Ess, unlanded\)' 'restoredEss = restoredM.Ess'
mut "M3 the carriedToLand filter is removed" main.go \
  'landRels := relsWithout\(carryRels, unlanded\)' 'landRels := carryRels'
mut "M4 the refusal becomes the walk-only publish" main.go \
  'if split && !mediaCarryRan \{' 'if false && split && !mediaCarryRan {'
mut "M5 walkChunks no longer skips a media temp" incremental_seal.go \
  'if info\.Mode\(\)\.IsRegular\(\) && isMediaTempName\(info\.Name\(\)\) \{' 'if false {'
mut "M6 the landed-roster check is removed (every background rel unlanded)" media_after_gate.go \
  'if landed == nil \|\| !landed\(rel\) \{' 'if true {'
mut "M7 the refusal is narrowed to the inner switch (the outer-gate decline publishes)" main.go \
  'if split && !mediaCarryRan \{' 'if split && !mediaCarryRan && mediaEssentialCarryOn(profile) && len(chunks) > 0 {'
mut "M8 the overlay under-walk no longer skips a media temp" incremental_seal.go \
  'if uinfo\.Mode\(\)\.IsRegular\(\) && isMediaTempName\(uinfo\.Name\(\)\) \{' 'if false {'
mut "M9 tarDirTo no longer skips a media temp" main.go \
  'if info\.Mode\(\)\.IsRegular\(\) && isMediaTempName\(info\.Name\(\)\) \{(\n\t\t\treturn nil // NWP-20261128-03: a media writer)' 'if false {\1'
mut "M10 the progress pre-walk prices a media temp" main.go \
  'if fi\.Mode\(\)\.IsRegular\(\) && isMediaTempName\(fi\.Name\(\)\) \{' 'if false {'
mut "M11 a marker without a roster is not a split" main.go \
  '\(aftergateActive\(rcptRef, splitRH\) \|\| \(splitRH == "" && aftergateMarkerPresent\(rcptRef\)\)\)' '(aftergateActive(rcptRef, splitRH))'
mut "M12 the landed roster is read after the walk, not before it" main.go \
  'unlandedBackground\(restoredM, landedPre\)' 'unlandedBackground(restoredM, loadLandedRoster(rcptRef, dk)); _ = landedPre'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
