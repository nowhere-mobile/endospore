#!/usr/bin/env bash
# test-release-gen.sh [--mutate] -- runs release_gen_test.go (NWP-20261029-04, the release generation a snapshot
# delete bumps so every other handset drops its blob cache); --mutate re-runs it against copies of release_gen.go /
# main.go with each guard broken in turn, injected with `go test -overlay`, so the source tree is never edited. Each
# mutant must be CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL
# line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUNRE='RelGen|ReleaseGen|BlobCacheDrop|CarryForwardCarriesReleaseGen|VaultFieldsAreClassified'

out=$(go test -count=1 -run "$RUNRE" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label="$1" src="$2" m ov out
  m=$(mktemp -p "$W" mut.XXXXXX) || return 1
  ov=$(mktemp -p "$W" overlay.XXXXXX) || return 1
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
  out=$(go test -count=1 -overlay "$ov" -run "$RUNRE" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label"
  elif ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
mut "G1 the pushProfile call removed" main.go '!strings\.Contains\(profile, "#"\) && distrustBlobCacheIfReleased\(blobCachePath\(\), ref, relGen\)' 'false'
mut "G2 the comparison is < instead of !=" release_gen.go 'seen != gen' 'seen < gen'
mut "G3 the restore call removed" main.go '\t\t\trelGenAtRestore\(base, profile, pass, restoredHead\)\n' '\n'
mut "G4 the restore only records" release_gen.go 'if distrustBlobCacheIfReleased\(blobCachePath\(\), relGenHeadKey\(base, profile, pass\), gen\) \{' 'if relGenRecord(blobCachePath(), relGenHeadKey(base, profile, pass), gen) != nil {'
mut "G5 blobCacheDrop leaves the in-memory set" release_gen.go '\tblobCache = nil\n' '\t_ = blobCache\n'
mut "G6 carryForward drops the field" main.go '\tnv\.ReleaseGen = old\.ReleaseGen[^\n]*\n' '\n'
mut "G7 the check runs for scope seals too" main.go '!strings\.Contains\(profile, "#"\) && distrustBlobCacheIfReleased' 'distrustBlobCacheIfReleased'
mut "G8 the restore check runs for scope restores too" main.go 'if strings\.IndexByte\(profile, '"'"'#'"'"'\) < 0 \{\n\t\t\trelGenAtRestore\(base, profile, pass, restoredHead\)\n\t\t\}' 'relGenAtRestore(base, profile, pass, restoredHead)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
