#!/usr/bin/env bash
# test-tel-replay-persist.sh [--mutate] -- runs tel_replay_persist_test.go (NWP-20261021-08); --mutate re-runs it
# against telephony_arrival.go with each part of the persisted replay table broken in turn, restoring the file on
# exit. Each mutant must be CONVICTED by a test failure; one that fails to apply, or fails to compile, counts as a
# failure.
set -uo pipefail
cd "$(dirname "$0")"
SRC=telephony_arrival.go
RUN=(go test -count=1 -run 'TestTelReplayPersist_' .)
W=$(mktemp -d)
trap '[ -f "$W/orig" ] && cp -f "$W/orig" "$SRC"; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | tail -5
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/orig"
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local res
  python3 - "$SRC" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/orig" "$SRC"
}
mut "M1 the put's append removed" '\tn, err := f\.Write\(\[\]byte\(line\)\)\n' '\tn, err := len(line), error(nil)\n'
mut "M2 the load skipped" '(\ttelReplayLoaded = true\n)(\tb, err := os\.ReadFile)' '\1\ttelReplayKey = newTelReplayKey()\n\treturn\n\2'
mut "M3 RemoveTag not persisted" '\tif changed && telReplayKeyOn && !telReplayNoDisk \{\n\t\ttelReplayRewrite\(\)\n\t\}\n' '\t_ = changed\n'
mut "M4 the load keeps expired entries" 'now-at >= telReplayTTL\.Milliseconds\(\) \|\| seen\[id\]' 'seen[id]'
mut "M5 the load stops at the first bad line" '(f\[0\] != strings\.ToLower\(f\[0\]\) \{\n\t\t\tdropped = true\n\t\t\t)continue' '\1break'
mut "M6 a fresh key minted every run" 'telReplayKey = append\(\[\]byte\(nil\), b\.\.\.\)' 'telReplayKey = newTelReplayKey()'
mut "M7 RemoveTag does not load" '(func telReplayRemoveTag\(tag string\) \{\n)\ttelReplayLoad\(\)\n' '\1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
