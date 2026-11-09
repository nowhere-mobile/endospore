#!/usr/bin/env bash
# test-in-park.sh [--mutate] -- runs in_park_test.go (NWP-20261129-17, backlog "A sign-in whose restore fails has already
# moved the live or cold-locked session's per-login state out of `$STATE`", h59 #2: roamd keeps the park on OK and the
# daemon drops or restores it). --mutate re-runs it against a COPY of the package with one rule broken in turn. Each
# mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestInPark' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" "$W/vendor-common/bin" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
cp ../vendor-common/bin/nowhere_roamd.sh "$W/vendor-common/bin/" || exit 2   # K5 reads it by this relative path
res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { printf '%s\n' "$res"; echo "== the unmutated copy does not pass"; exit 1; }
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
mut() {
  local label="$1" f="$2" res rc
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 putBackInPark skips removing the attempt's name" in_park.go \
  'os\.RemoveAll\(filepath\.Join\(dest, entry\)\)\n' '\n'
mut "M2 the abandoned hook is removed" main.go \
  'putBackInPark\(dest, "worker lane "\+lane\.svc\+": the abandoned in op"\)\n' '\n'
mut "M3 the hook runs for any abandoned op" main.go \
  'if abandoned == "in" \{' 'if abandoned != "" {'
mut "M4 dropInPark is removed from handleRoamIn" main.go \
  '\t\tdropInPark\(dest\) // NWP-20261129-17[^\n]*\n' ''
mut "M5 the ERR-UNRECORDED put-back is removed" main.go \
  'putBackInPark\(dest, "roam-in user "\+uid\+" not recorded"\) // NWP-20261129-17[^\n]*\n' '\n'
mut "M6 the BLANK NET put-back is removed" locked_head.go \
  'putBackInPark\(dest, "roam-in BLANK NET after the restore"\)\n' '\n'
mut "M7 a name is dropped from inParkNames" in_park.go \
  ', "\.fido2slots"\}' '}'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
