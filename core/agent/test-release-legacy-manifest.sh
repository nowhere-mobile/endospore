#!/usr/bin/env bash
# test-release-legacy-manifest.sh [--mutate] -- runs release_legacy_manifest_test.go (NWP-20261113-14: a manifest that
# decrypts under the DK and is not CDC -- the creation state -- names only its own blob, so a profile delete releases
# its vault past it and a snapshot delete frees exactly its blob); --mutate re-runs it against copies of
# snapshot_release.go with the rule broken in turn, injected with `go test -overlay`, so the source tree is never
# edited. Each mutant must be CONVICTED by a real `--- FAIL`; one that does not apply or does not compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=snapshot_release.go
PAT='TestReleaseLegacyManifest'

out=$(go test -count=1 -run "$PAT" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local label="$1" m ov out rc
  m=$(mktemp -p "$W" mut.XXXXXX.go) && ov=$(mktemp -p "$W" overlay.XXXXXX.json) || exit 2
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
  out=$(go test -count=1 -overlay "$ov" -run "$PAT" . 2>&1); rc=$?
  score_mutant "$label" "$rc" "$out" || fails=$((fails+1))
}
mut "M1 the non-CDC error restored" \
  '(if !bytes\.HasPrefix\(pt, cdcMagic\) \{\n\t\t)into\["blob/"\+manifestHash\] = true\n\t\treturn nil' \
  '\1return errors.New("manifest is not a CDC manifest")'
mut "M2 a non-CDC manifest returns nil without its own blob" \
  '(if !bytes\.HasPrefix\(pt, cdcMagic\) \{\n\t\t)into\["blob/"\+manifestHash\] = true\n\t\t' \
  '\1'
mut "M3 a CDC manifest whose JSON does not parse read as self-contained" \
  'return errors\.New\("manifest does not parse"\)' \
  'into["blob/"+manifestHash] = true\n\t\treturn nil'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
