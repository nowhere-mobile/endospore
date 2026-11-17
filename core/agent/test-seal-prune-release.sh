#!/usr/bin/env bash
# test-seal-prune-release.sh [--mutate] -- runs seal_prune_release_test.go (NWP-20261204-06: a bare-vault seal releases
# the chunks of the snapshots its retention dropped); --mutate re-runs it against copies of seal_prune_release.go (and
# of main.go for P5) with each guard broken in turn, injected with `go test -overlay`, so the source tree is never
# edited. Each mutant must be CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies
# without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='SealPruneRelease'
RUN=(go test -count=1 -run "$PAT" .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <source file> <label> <python-regex pattern> <replacement>
  local src="$1" label="$2" m ov out
  m=$(mktemp -p "$W" mut.XXXXXX) || exit 2
  mv "$m" "$m.go"; m="$m.go"
  ov=$(mktemp -p "$W" overlay.XXXXXX) || exit 2
  python3 - "$src" "$m" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(n)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run "$PAT" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label by $(grep -o -- '--- FAIL: [A-Za-z]*' <<<"$out" | sed 's/--- FAIL: //' | sort -u | tr '\n' ' ')"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
S=seal_prune_release.go
mut $S "P1 Dropped ignores newHist (Dropped)" 'range newHist \{' 'range []headSnap{} {'
mut $S "P2 eligibility ignores multiDeviceEnabled (Eligible)" '!multiDeviceEnabled\(\) && ' ''
mut $S "P3 the keep set skips kept.History (Frees)" 'keep, err := manifestKeepSet\(base, dk, kept\)' 'keep, err := manifestKeepSet(base, dk, &vault{Manifest: kept.Manifest})'
mut $S "P4 an unreadable manifest skipped, not an error (Unreadable)" 'keep, err := manifestKeepSet\(base, dk, kept\)\n\tif err != nil \{\n\t\treturn nil, err\n\t\}' 'keep, _ := manifestKeepSet(base, dk, kept)\n\tif keep == nil {\n\t\tkeep = map[string]bool{}\n\t}'
mut main.go "P5 the ReleaseGen bump removed (Frees)" 'v\.ReleaseGen\+\+\n\t\t\tspr = &sealPrunePending' 'spr = &sealPrunePending'
mut $S "P6 the gate ignores landed (Gate)" 'return landed && !refused && !stopped' 'return !refused && !stopped'
mut $S "P7 the eviction skipped (Frees)" 'evicted, eerr := blobCacheEvict\(cache, set\)' 'evicted, eerr := 0, error(nil)'
mut $S "P8 the commitment sent in place of the preimage (Frees)" 'hex\.EncodeToString\(blobReleaseProof\(p\.dk, k\)\)' 'func() string { _ = hex.EncodeToString; return blobReleaseCommit(p.dk, k) }()'
mut $S "P9 the skip record removed (Unreadable)" 'skip\(why\)\n\t\trelGenRecord\(cache, rk, p\.kept\.ReleaseGen\)' 'skip(why)'
mut $S "P10 the set computed with no wait (SlowStore)" 'goSafe\("seal-prune-set", func\(\) \{(.*?)\n\t\}\)\n' 'func() {\1\n\t}()\n'
mut $S "P11 the RecoveryRef read-back removed (RecoveryRefLags)" 'if p\.kept\.RecoveryRef != "" && read\(p\.kept\.RecoveryRef\) != p\.vh \{' 'if false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
