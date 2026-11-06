#!/usr/bin/env bash
# test-delete-release.sh [--mutate] -- runs delete_release_test.go (NWP-20261107-07: a verified profile delete releases
# the vault's blobs on per-blob proofs; NWP-20261117-13: and the scope heads' blobs, read before the purge, each under
# the key its own seal leased with); --mutate re-runs it against copies of delete_release.go and main.go with each
# guard broken in turn, injected with `go test -overlay`, so the source tree is never edited. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL line counts as
# a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='TestDeleteRelease'
RUN=(go test -count=1 -run "$PAT" .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label="$1" src="$2" m="$W/mut.go" ov="$W/overlay.json" out
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
    echo "  convicted $label"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "D1 released on gone too" main.go 'if state == "deleted" \{(\n\t+releaseDeletedProfileFn)' 'if state != "notfound" {\1'
mut "D2 History skipped" delete_release.go 'for _, h := range v\.History \{' 'for _, h := range []headSnap{} {'
mut "D3 a manifest error ignored" delete_release.go '(h\.Manifest, set\); err != nil \{\n\t+)return nil, err' '\1continue'
mut "D4 proofs from another key" delete_release.go 'blobReleaseProof\(dk, k\)' 'blobReleaseProof(blobReleaseKey(dk), k)'
mut "D5 the call before the verify loop" main.go '(\tscoped = append\(scoped, accountDeleteRefs[^\n]*\n)(.*?)(\t// Q119 \(NWP-20261107-07\)[^\n]*\n[^\n]*\n\tif state == "deleted" \{\n[^\n]*\n\t\}\n)' '\1\3\2'
mut "D6 the eviction removed" delete_release.go 'blobCacheEvict\(workerBlobCachePath\(\), union\)' '0, error(nil)'
mut "D7 the release waited on inline" delete_release.go 'goSafe\("delete-release", func\(\) \{(.*?)\n\t\}\)\n' 'func() {\1\n\t}()\n'
mut "D8 the scope heads captured after the purge" main.go '(\n\t+if dk != nil && capMode\(\) && !multiDeviceEnabled\(\) \{\n\t+heads = deleteScopeHeads\(base, name, pass\)\n\t+\})(.*?\n)(\tif refusedTombs > 0 \{)' '\2\1\n\3'
mut "D9 a scope's proofs under the DK" delete_release.go 'blobReleaseProof\(s\.key, k\)' 'blobReleaseProof(dk, k)'
mut "D10 the wallet's proof under its derived key" delete_release.go '(if scopeSealedUnderDK\(h\.suf\) \{\n\t+if scopeKeyOpens\(base, h\.head, dk\) \{\n\t+return )dk' '\1h.derived'
mut "D11 the scope index skipped, deriveKey only" delete_release.go 'if rec, ok := idx\[h\.suf\]; ok \{' 'if rec, ok := idx[h.suf]; ok && false {'
mut "D12 a vault-shaped scope head read as a manifest" delete_release.go 'if sv, isV := parseVault\(blob\); isV \{' 'if sv, isV := parseVault(blob); isV && false {'
mut "D13 the capture reads a value the probe already carried" delete_release.go 'if !have && !\(isS3\(base\) && capMode\(\)\) \{' 'if !have {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
