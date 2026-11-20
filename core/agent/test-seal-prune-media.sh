#!/usr/bin/env bash
# test-seal-prune-media.sh [--mutate] -- runs seal_prune_media_test.go (NWP-20261208-14: a #media head that is a vault
# releases at its seal the chunks its retention dropped, keeps the media export's pinned manifest, and stops above
# sealPruneMediaMaxKeys keys compared) with seal_prune_scope_test.go; --mutate re-runs them against copies of
# seal_prune_release.go with each guard broken in turn, injected with `go test -overlay`, so the source tree is never
# edited. Each mutant must be CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies
# without a FAIL line counts as a failure.
#   M1 relGenScope without #media                -> SealPruneMediaFrees
#   M2 the pin not unioned into keep             -> SealPruneMediaPinKept
#   M3 the legacy pointer not read               -> SealPruneMediaLegacyPinKept
#   M4 a pin read error taken as no pin          -> SealPruneMediaPinUnreadable
#   M5 the bound check removed                   -> SealPruneMediaTooLarge (media)
#   M6 the bound applied to every head           -> SealPruneMediaTooLarge (bare)
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='SealPruneMedia|SealPruneScope'
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
  out=$(go test -count=1 -overlay "$ov" -run "$PAT" -v . 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label by $(grep -o -- '--- FAIL: [A-Za-z/]*' <<<"$out" | sed 's/--- FAIL: //' | sort -u | tr '\n' ' ')"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
S=seal_prune_release.go
mut $S "M1 relGenScope without #media (MediaFrees)" 'case "#de", "#sys", "#keys", "#apps", "#media":' 'case "#de", "#sys", "#keys", "#apps":'
mut $S "M2 the pin not unioned into keep (MediaPinKept)" 'for k := range pin \{\n\t\t\tkeep\[k\] = true' 'for k := range pin {\n\t\t\t_ = k'
mut $S "M3 the legacy pointer not read (MediaLegacyPinKept)" 'h = read\("export/" \+ name \+ "#media"\)' 'h = read("export/" + name + "#media-mutant")'
mut $S "M4 a pin read error taken as no pin (MediaPinUnreadable)" 'pin, err := sealPruneMediaPin\(base, name, pass\)\n\t\tif err != nil \{\n\t\t\treturn nil, err\n\t\t\}' 'pin, _ := sealPruneMediaPin(base, name, pass)'
mut $S "M5 the bound check removed (MediaTooLarge media)" 'return media && n > sealPruneMediaMaxKeys' 'return false'
mut $S "M6 the bound applied to every head (MediaTooLarge bare)" 'return media && n > sealPruneMediaMaxKeys' 'return n > sealPruneMediaMaxKeys'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
