#!/usr/bin/env bash
# test-seal-pathmax.sh [--mutate] -- runs seal_pathmax_test.go (NWP-20261203-29, the backlog row "A file in an app's
# data whose path is longer than PATH_MAX is neither sealed nor counted as unreadable: the sign-out seals OK and no log
# names it"): a path past PATH_MAX makes both seal walks blind and the refusal names the app; an unfetched package dir
# the walk skips has its local files outside cache/ and code_cache/ counted, counts only. --mutate breaks a COPY of the
# package in the suite's temp root, one guard at a time, so the source tree is never edited. Each mutant must be
# CONVICTED by a `--- FAIL` line of the test named for it; one that does not apply, does not compile, or fails without
# that line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='TestSealPathMax|TestSealUnfetchedLocal'

out=$(go test -count=1 -run "$PAT" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

mkdir "$W/pkg" "$W/tmp" || exit 2
cp -a . "$W/pkg/" || exit 2
export TMPDIR="$W/tmp" GOTMPDIR="$W/tmp"
SRC=$PWD
cd "$W/pkg" || exit 2

fails=0
mut() { # mut <label> <file> <required --- FAIL test> <python-regex pattern> <replacement> [<pattern> <replacement>]...
  local label="$1" src="$2" want="$3" out nl=$'\n'
  python3 - "$src" "${@:4}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp "$SRC/$src" "$src"; return; }
import re,sys
src=sys.argv[1]
rest=sys.argv[2:]
s=open(src).read()
for pat,rep in zip(rest[0::2],rest[1::2]):
    s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(src,'w').write(s)
PY
  if ! out=$(go vet . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); cp "$SRC/$src" "$src"; return
  fi
  out=$(go test -count=1 -run "$PAT" . 2>&1)
  if [[ "$nl$out" == *"$nl"*"--- FAIL: $want "* ]]; then
    echo "  convicted $label: --- FAIL: $want"
  elif [[ "$nl$out" == *"$nl"*'--- FAIL'* ]]; then
    echo "  WRONG-FAIL $label -- failed, but not in $want:"; grep -- '--- FAIL' <<<"$out"; fails=$((fails+1))
  elif [[ "$nl$out" != *"${nl}ok"* ]]; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; tail -15 <<<"$out"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
  cp "$SRC/$src" "$src"
}
mut "M1 ENAMETOOLONG not blind" incremental_seal.go TestSealPathMax_WalkAndTarRefuse \
  'return err != nil && !errors\.Is\(err, fs\.ErrNotExist\)' \
  'return err != nil && !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, unix.ENAMETOOLONG)'
mut "M2 cache/ and code_cache/ counted" incremental_seal.go TestSealUnfetchedLocal_CountsOnlyThePackageDir \
  'rel == "cache" \|\| rel == "code_cache"' 'rel == "-"'
mut "M3 the hold counted" incremental_seal.go TestSealUnfetchedLocal_CountsOnlyThePackageDir \
  '!strings\.Contains\(filepath\.ToSlash\(rel\), "/"\)' 'true'
mut "M4 the raw profile printed" incremental_seal.go TestSealUnfetchedLocal_LineIsCountsOnly \
  'logProfile\(profile\), st\.unfLocalPkgs' 'profile, st.unfLocalPkgs'
mut "M5 unreadable entries not bounded" incremental_seal.go TestSealUnfetchedLocal_UnreadableEntriesCountTowardTheBound \
  'n\+\+\n\t\tif n > unfetchedLocalMax \{\n\t\t\treturn filepath\.SkipAll\n\t\t\}\n\t\tif err != nil \{\n\t\t\treturn nil\n\t\t\}' \
  'if err != nil {
			return nil
		}
		n++
		if n > unfetchedLocalMax {
			return filepath.SkipAll
		}'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
