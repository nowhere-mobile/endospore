#!/usr/bin/env bash
# test-snapshot-delete.sh [--mutate] -- runs snapshot_delete_test.go and the rollback tests (NWP-20261027-04, the
# DELETE-SNAPSHOT verb); --mutate re-runs them against copies of snapshot_delete.go with each guard broken in turn,
# injected with `go test -overlay`, so the source tree is never edited. Each mutant must be CONVICTED by a real
# `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=snapshot_delete.go
RUN=(go test -count=1 -run 'SnapshotDelete|DeleteSnapshot|Rollback' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local label="$1" m="$W/mut.go" ov="$W/overlay.json" out
  python3 - "$SRC" "$m" "$2" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(n)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$SRC" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run 'SnapshotDelete|DeleteSnapshot|Rollback' . 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "S1 the entry found in the pre-bracket copy" 'i, err = findEntry\(cur\)' 'i, err = findEntry(v)'
mut "S2 Version bumped" '\t\tsignVault\(cur, dk\)' '\t\tcur.Version++\n\t\tsignVault(cur, dk)'
mut "S3 the live-version guard removed" 'if version == v\.Version \{' 'if false {'
mut "S4 a refusal ignored" 'if vd\.Refused\(\) \{' 'if false && vd.Refused() {'
mut "S5a the sealAnnounced guard removed" 'if sealAnnounced\(\) \{' 'if false {'
mut "S5b the endUnsavedBlocked guard removed" 'if why := endUnsavedBlocked\(uid\); why != "" \{' 'if why := endUnsavedBlocked(uid); false && why != "" {'
mut "S6 the panic recover removed" 'if r := recover\(\); r != nil \{' 'if r := any(nil); r != nil {'
mut "S7 the release called even when the publish was refused" 'if perr == nil && !vd\.Refused\(\) && published != nil \{' 'if perr == nil && published != nil {'
mut "S8 the generation bump removed" '\t\tcur\.ReleaseGen\+\+[^\n]*\n' ''
mut "S9 the eviction after the request" '\tevicted, eerr := blobCacheEvict\(cache, set\)\n\tif eerr == nil \{\n\t\trelGenRecord\(cache, hk, kept\.ReleaseGen\)\n\t\}\n(.*?)\n\tswitch \{' '\1\n\tevicted, eerr := blobCacheEvict(cache, set)\n\tif eerr == nil {\n\t\trelGenRecord(cache, hk, kept.ReleaseGen)\n\t}\n\tswitch {'
mut "S10 a release-set error ignored (the kept versions not read)" 'snapshotReleaseSet\(base, dk, removed, kept\)' 'snapshotReleaseSet(base, dk, removed, nil)'
mut "S11 the generation recorded after a failed eviction" 'if eerr == nil \{' 'if true || eerr == nil {'
mut "S12 the read-back removed" 'if now != publishedHead \{' 'if false && now != publishedHead {'
mut "S13 the per-unit heads guard removed" 'if multiDeviceEnabled\(\) \{' 'if false {'
mut "S14 the release waited inline" 'case <-time\.After\(snapshotReleaseWait\):' 'case <-make(chan time.Time):'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
