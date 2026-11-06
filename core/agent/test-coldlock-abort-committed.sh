#!/usr/bin/env bash
# test-coldlock-abort-committed.sh [--mutate] -- NWP-20261124-04: COLD-LOCK-ABORT after the cold lock's point of no
# return answers COMMITTED when .coldlock names the abort's uid, and OK for every other rejection; the IDLE-TRACE
# vocabulary keeps the gate's `abort committed` line. --mutate re-runs the tests against a COPY of the package with
# each part broken in turn. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to
# compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestColdLockAbort|TestIdleTraceKeepsTheChooserEvents|TestIdleTraceVocabularyCoversTheChooser' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

# The copy sits at $W/agent beside $W/chooser, so the vocabulary test's ../chooser read finds the chooser sources.
P="$W/agent"; mkdir -p "$P" "$W/chooser/src/com/nowhere/chooser" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
cp ../chooser/src/com/nowhere/chooser/*.java "$W/chooser/src/com/nowhere/chooser/" || exit 2
fails=0
# apply <file> <python-regex> <replacement>: one match exactly, or it fails.
apply() {
  python3 - "$1" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
}
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the tests there, then restore the file.
mut() {
  local label="$1" f="$2" res orig
  orig=$(mktemp -p "$W") || exit 2
  cp "$P/$f" "$orig"
  if apply "$P/$f" "$3" "$4"; then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $label"
    else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$orig" "$P/$f"
}
mut "M1 the COMMITTED arm answers OK" main.go \
  'fmt\.Fprint\(conn, "COMMITTED\\n"\)' 'fmt.Fprint(conn, "OK\\n")'
mut "M2 the uid comparison dropped" main.go \
  '&& coldLockedUID\(dest\) == auid \{' '&& coldLockedUID(dest) != "" {'
mut "M3 the live-session check dropped" main.go \
  'if perr == nil && auid != "" && luid == "" && coldLockedUID' 'if perr == nil && auid != "" && coldLockedUID'
mut "M4 the stamp check dropped" main.go \
  'if perr == nil && auid != "" && luid == "" && coldLockedUID' 'if auid != "" && luid == "" && coldLockedUID'
mut "M5 committed dropped from the IDLE-TRACE words" idle_trace.go \
  ' "committed": true,' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
