#!/usr/bin/env bash
# test-app-dormant.sh [--mutate] -- runs app_dormant_test.go (NWP-20261128-01): an On-demand/Auto package roamd's carry
# branch staged nothing for keeps its app-index line, _meta and deferred APK over a head sealed with no app index, the
# stored index wins where it names the package, and the #apps presence guard refuses a seal that keeps a package's
# deferred bytes but drops its line. --mutate breaks app_carry.go / main.go one part at a time and restores both on exit.
# Each mutant must be CONVICTED by the named test's `--- FAIL`; one that fails to apply, or to compile, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
CARRY=app_carry.go
MAIN=main.go
trap 'for f in "$CARRY" "$MAIN"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" || exit 2
export TMPDIR="$W" GOTMPDIR="$W/gotmp"
RUN=(go test -count=1 -run 'TestDormant' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$CARRY" "$W/$CARRY.orig"; cp "$MAIN" "$W/$MAIN.orig"
fails=0
# mut <label> <file> <python-regex> <replacement> <convicting test>...
mut() {
  local label="$1" file="$2" pat="$3" rep="$4" res want
  shift 4
  python3 - "$file" "$pat" "$rep" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  cp -f "$W/$CARRY.orig" "$CARRY"; cp -f "$W/$MAIN.orig" "$MAIN"
}
mut "M1 the adoption call removed" "$MAIN" 'ad, aerr := adoptDormantApps\(src, dd, oldM\.Apps, effDrop\)' 'ad, aerr := []string(nil), error(nil)' TestDormantD1AdoptsOverAnIndexlessHead
mut "M2 adopt even when the stored index names the package" "$CARRY" '(if pkg == "\." \|\| pkg == "\.\.") \|\| oldApps\[pkg\] != "" \{' '\1 {' TestDormantD5StoredLineWins
mut "M3 the drop check removed from the adoption" "$CARRY" '(oldApps\[pkg\] != "" \{\n\t\t\tcontinue\n\t\t\}\n)\t\tif dropPkgForFileRel\(pkg\+"/base\.apk", drop\) \{\n\t\t\tcontinue\n\t\t\}\n' '\1' TestDormantD3DropListIsNotAdopted
mut "M4 the line-lost check removed" "$MAIN" '\t\t\t\t\tlineLost\+\+\n' '\t\t\t\t\tlineLost += 0\n' TestDormantD4IndexlessHeadWithoutDormantIsRefused
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
