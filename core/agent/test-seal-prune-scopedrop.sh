#!/usr/bin/env bash
# test-seal-prune-scopedrop.sh [--mutate] -- runs seal_prune_scopedrop_test.go (NWP-20261208-15: a bare-shaped #de,
# #sys, #keys or #apps seal records the chunks it stopped naming, the next due bare-vault seal releases them under the
# bare vault's release generation, and a bare-shaped scope push checks that generation), with the seal_prune_scope
# tests and the two release_gen_test.go tests that pin a bare-shaped scope head; --mutate re-runs them against copies
# of seal_prune_release.go and main.go with each guard broken in turn, injected with `go test -overlay`, so the source
# tree is never edited. Each mutant must be CONVICTED by a real `--- FAIL`; one that does not apply, does not compile,
# or dies without a FAIL line counts as a failure.
#   D1 recorded with scopeReleaseOn off                    -> SealPruneScopeDropOffRecordsNothing
#   D2 freed without subtracting the new manifest          -> SealPruneScopeDropRecordsFreed
#   D3 released without subtracting the current head       -> SealPruneScopeDropReAddedKept
#   D4 no bump for a release of scope records alone        -> SealPruneScopeDropBareSealReleases
#   D5 the gap check removed                               -> SealPruneScopeDropGapHolds
#   D6 the vault check at release removed                  -> SealPruneScopeDropVaultSkipped
#   D7 #media eligible                                     -> SealPruneScopeDropMediaNotRecorded
#   D8 the push's bare generation check removed            -> SealPruneScopeDropPushChecksBareGen
#   D9 records kept after the attempt                      -> SealPruneScopeDropBareSealReleases
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='SealPruneScopeDrop|SealPruneScope|ReleaseGenIgnoresScopes|ReleaseGenScopeRestoreIgnoresRelGen'
RUN=(go test -count=1 -run "$PAT" -v .)

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
mut $S "D1 recorded with scopeReleaseOn off (OffRecordsNothing)" 'scopeReleaseOn && scopeDropSuffix\(profile\)' 'scopeDropSuffix(profile)'
mut $S "D2 freed without subtracting the new manifest (RecordsFreed)" 'delete\(freed, "blob/"\+newManifest\)\n\tfor _, c := range chunks \{\n\t\tdelete\(freed, "blob/"\+c\)\n\t\}\n\tfor _, d := range deferred \{\n\t\tfor _, c := range d\.Chunks \{\n\t\t\tdelete\(freed, "blob/"\+c\)\n\t\t\}\n\t\}\n' ''
mut $S "D3 released without subtracting the current head (ReAddedKept)" 'if !keep\[k\] \{' 'if keep != nil {'
mut main.go "D4 no bump for a release of scope records alone (BareSealReleases)" '\t\t\tv\.ReleaseGen\+\+\n\t\t\tspr = &sealPrunePending' '\t\t\tif len(dropped) > 0 {\n\t\t\t\tv.ReleaseGen++\n\t\t\t}\n\t\t\tspr = &sealPrunePending'
mut $S "D5 the gap check removed (GapHolds)" 'if haveLast && now\.Sub\(time\.Unix\(last, 0\)\) < scopeDropMinGap \{\n\t\treturn nil\n\t\}\n' '_, _ = haveLast, last\n'
mut $S "D6 the vault check at release removed (VaultSkipped)" 'if _, isV := parseVault\(headBlobGet\(base, head\)\); isV \{\n\t\treturn scopeDropResult\{why: "the scope head is a vault now"\}\n\t\}\n' ''
mut $S "D7 #media eligible (MediaNotRecorded)" 'var scopeDropScopes = \[\]string\{"#de", "#sys", "#keys", "#apps"\}' 'var scopeDropScopes = []string{"#de", "#sys", "#keys", "#apps", "#media"}'
mut main.go "D8 the push's bare generation check removed (PushChecksBareGen)" 'if v == nil && scopeDropChecksBare\(profile\) \{\n\t\trelGenAtBareShapedScope\(base, profile, pass, bareHead\)\n\t\}\n' ''
mut $S "D9 records kept after the attempt (BareSealReleases)" 'if len\(p\.scopes\) > 0 \{ // NWP-20261208-15[^\n]*\n\t\tdefer scopeDropDone\(blobCachePath\(\), p\.scopes\)\n\t\}\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
