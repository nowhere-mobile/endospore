#!/usr/bin/env bash
# test-seal-prune-scope.sh [--mutate] -- runs seal_prune_scope_test.go (NWP-20261207-03: a #de, #sys, #keys or #apps
# head, and since NWP-20261208-14 a #media one, that is a vault releases at its seal the chunks its retention dropped,
# and its release generation is checked at that scope's push and restore), with TestSealPruneReleaseEligible and the
# two release_gen_test.go tests that pin a bare-shaped scope head; --mutate re-runs them against copies of
# seal_prune_release.go, release_gen.go and main.go with each guard broken in turn, injected with `go test -overlay`,
# so the source tree is never edited. Each mutant must be CONVICTED by a real `--- FAIL`; one that does not apply,
# does not compile, or dies without a FAIL line counts as a failure.
#   S1 relGenScope admits #wallet                      -> SealPruneScopeScope
#   S2 eligibility back to bare only                   -> SealPruneScopeVaultFrees, SealPruneReleaseEligible
#   S3 the push check back to bare only                -> SealPruneScopePushDistrust
#   S4 the restore arm's relGenAtScopeRestore removed  -> SealPruneScopeRestoreDistrust
#   S5 relGenAtScopeRestore without its vault check    -> SealPruneScopeRestoreDistrust, ReleaseGenScopeRestoreIgnoresRelGen
#   S6 the push check without `v != nil`               -> ReleaseGenIgnoresScopes
#   S7 relGenScope by strings.Contains                 -> SealPruneScopeScope ("a#dex")
#   S8 scopeReleaseOn initialised false                -> SealPruneScopeOnByDefault
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='SealPruneScope|SealPruneReleaseEligible|TestReleaseGenIgnoresScopes|TestReleaseGenScopeRestoreIgnoresRelGen'
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
mut $S "S1 relGenScope admits #wallet (Scope)" 'case "#de", "#sys", "#keys", "#apps", "#media":' 'case "#de", "#sys", "#keys", "#apps", "#media", "#wallet":'
mut $S "S2 eligibility back to bare only (VaultFrees, Eligible)" 'relGenScope\(profile\) && \(strings\.IndexByte\(profile, '"'"'#'"'"'\) < 0 \|\| scopeReleaseOn\)' '!strings.Contains(profile, "#")'
mut main.go "S3 the push check back to bare only (PushDistrust)" '\(!strings\.Contains\(profile, "#"\) \|\| \(v != nil && relGenScope\(profile\)\)\) && distrustBlobCacheIfReleased' '!strings.Contains(profile, "#") && distrustBlobCacheIfReleased'
mut main.go "S4 the restore arm's relGenAtScopeRestore call removed (RestoreDistrust)" '\n\s*if strings\.IndexByte\(profile, '"'"'#'"'"'\) >= 0 \{\n\s*relGenAtScopeRestore\(base, profile, pass, restoredHead\)\n\s*\}' ''
mut release_gen.go "S5 relGenAtScopeRestore without its vault check (RestoreDistrust, ScopeRestoreIgnoresRelGen)" 'if !isV \{\n\t\treturn[^\n]*\n\t\}' 'if !isV {\n\t\tv = &vault{}\n\t}'
mut main.go "S6 the push check without v != nil (ReleaseGenIgnoresScopes)" '\(v != nil && relGenScope\(profile\)\)' 'relGenScope(profile)'
mut $S "S7 relGenScope by strings.Contains (Scope)" 'switch profile\[i:\] \{\n\tcase "#de", "#sys", "#keys", "#apps", "#media":\n\t\treturn true\n\t\}\n\treturn false' 'return strings.Contains(profile[i:], "#de") || strings.Contains(profile[i:], "#sys") || strings.Contains(profile[i:], "#keys") || strings.Contains(profile[i:], "#apps") || strings.Contains(profile[i:], "#media")'
mut $S "S8 scopeReleaseOn initialised false (OnByDefault)" 'var scopeReleaseOn = true' 'var scopeReleaseOn = false'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
