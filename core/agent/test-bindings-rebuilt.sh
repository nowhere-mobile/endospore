#!/usr/bin/env bash
# test-bindings-rebuilt.sh [--mutate] -- runs bindings_rebuilt_test.go (NWP-20261110-01): the "#rebuilt" mark and the
# "#mine|<iccid>|" records of bindings.conf. Every rewrite of a flawed file marks it rebuilt, and in a rebuilt file a SIM
# no good line names is UNRESOLVED (never the device owner's) unless a mine record marks it. --mutate re-runs it against
# a COPY of core/agent under a temp root, bindings.go and bindings_check.go broken in turn; the checked-out tree is
# never touched. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as
# a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -run '^TestBindingsRebuilt' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent"
fails=0
mut() { # mut <label> <file in the copy> <python-regex pattern> <replacement>
  local res f
  for f in bindings.go bindings_check.go; do cp -f "$f" "$W/agent/$f"; done
  python3 - "$W/agent/$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(cd "$W/agent" && "${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
}
mut "M1 parse treats #rebuilt as damaged" bindings_check.go 'if row == bindingsRebuiltMark \{' 'if false && row == bindingsRebuiltMark {'
mut "M2 arrivalLine rebuilt check removed" bindings_check.go 'if st\.rebuilt && !st\.mineTag\(tag\) \{\n(\t+)return simBinding\{\}, lineDamaged' 'if false {\n\1return simBinding{}, lineDamaged'
mut "M3 arrivalLine ignores mineTag" bindings_check.go 'if st\.rebuilt && !st\.mineTag\(tag\) \{' 'if st.rebuilt {'
mut "M4 marksAfter drops || st.flawed" bindings.go 'rebuilt: st\.rebuilt \|\| st\.flawed' 'rebuilt: st.rebuilt'
mut "M5 setBindingOwner passes bindingsMarks{}" bindings.go '(func setBindingOwner.*?)writeBindingsMarked\(bs, st\.damaged, marksAfter\(st\)\)' '\1writeBindingsMarked(bs, st.damaged, bindingsMarks{})'
mut "M6 removeBindingOwnerEverywhere passes bindingsMarks{}" bindings.go '(func removeBindingOwnerEverywhere.*?)writeBindingsMarked\(out, damaged, marksAfter\(st\)\)' '\1writeBindingsMarked(out, damaged, bindingsMarks{})'
mut "M7 simUnboundNow ignores rebuilt" bindings_check.go 'return !st\.flawed && \(!st\.rebuilt \|\| st\.mineTag\(tag\)\)' 'return !st.flawed'
mut "M8 the serializer omits the mine records" bindings.go 'body \+= bindingsMinePrefix \+ iccid \+ "\|\\n"' '_ = iccid'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
