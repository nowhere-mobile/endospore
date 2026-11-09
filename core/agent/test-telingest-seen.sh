#!/usr/bin/env bash
# test-telingest-seen.sh [--mutate] -- runs telingest_seen_test.go (NWP-20261129-02): TELINGEST-SEEN writes one
# validated line of a delivery run's read-back counts to login.log, refuses anything but seven numbers each 0..99999,
# and never waits on sessionMu. --mutate breaks telingest_seen.go / main.go on a copy of the package. Each mutant must be
# CONVICTED by the named test's `--- FAIL`; one that fails to apply, or to compile, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" || exit 2
export TMPDIR="$W" GOTMPDIR="$W/gotmp"
RUN=(go test -count=1 -run 'TestTelIngestSeen' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

SEEN=telingest_seen.go
MAIN=main.go
cp -a . "$W/agent" || exit 2
cd "$W/agent" || exit 2
cp "$SEEN" "$W/$SEEN.orig" || exit 2
cp "$MAIN" "$W/$MAIN.orig" || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement> <convicting test>
mut() {
  local label="$1" file="$2" pat="$3" rep="$4" want="$5" res
  if ! python3 - "$file" "$pat" "$rep" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return
  fi
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
  else echo "  SURVIVED  $label -- no --- FAIL: $want"; tail -n 15 <<<"$res"; fails=$((fails+1)); fi
  cp -f "$W/$SEEN.orig" "$SEEN"; cp -f "$W/$MAIN.orig" "$MAIN"
}
mut "G1 six fields accepted" "$SEEN" 'len\(f\) != len\(n\) \{(.*?)for i := range n \{' 'len(f) != 6 && len(f) != 7 {\1for i := range f {' TestTelIngestSeenRefusesBadLines
mut "G2 a count dropped from the line" "$SEEN" ', mms parts not inserted=%d( \(NWP-20261129-02\)\\n",\s*n\[0\], n\[1\], n\[2\], n\[3\], n\[4\], n\[5\]), n\[6\]\)' '\1)' TestTelIngestSeenLogsCounts
mut "G3 the verb out of concurrentSafeCmd" "$MAIN" '\t\t"TELINGEST-SEEN",\n' '' TestTelIngestSeenIsConcurrentSafe
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
