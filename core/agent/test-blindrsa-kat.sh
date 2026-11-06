#!/usr/bin/env bash
# test-blindrsa-kat.sh [--mutate] -- runs the blindrsa package tests (NWP-20261031-14), incl. blindrsa_kat_test.go, which
# pins saltLen == 48, the SHA-384 hash and an EMSA-PSS vector computed outside Go. --mutate re-runs the package against
# a copy-restored blindrsa.go with K1 saltLen 48 -> 32, K2 Verify's SaltLength -> PSSSaltLengthAuto, K3 the 0x01 separator
# -> 0x02, K4 the 0xbc trailer -> 0xbd; each must be CONVICTED by a `--- FAIL` (inert, non-compiling and surviving
# mutants are failures). It then runs K1 and K2 WITHOUT blindrsa_kat_test.go, i.e. against the pre-change tests, and
# requires both to SURVIVE there: that is the proof the KAT test is needed. Restores everything on exit.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=blindrsa/blindrsa.go
KAT=blindrsa/blindrsa_kat_test.go
RUN=(go test -count=1 ./blindrsa/)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$SRC" "$W/blindrsa.go.orig"
cp "$KAT" "$W/kat.orig"
trap 'cp -f "$W/blindrsa.go.orig" "$SRC" 2>/dev/null; cp -f "$W/kat.orig" "$KAT" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/blindrsa.go.orig" "$SRC"; cp "$W/kat.orig" "$KAT"; }
# conv <label> <convict|survive>: run the package against the mutated tree, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [ "$2" = survive ]; then
    if [[ "$res" == *'--- FAIL'* ]]; then echo "  CONVICTED $1 -- the pre-change tests were meant to miss it"; fails=$((fails+1))
    elif [[ "$res" == ok* || "$res" == *$'\nok'* ]]; then echo "  survived  $1 (as expected: the old tests are blind to it)"
    else echo "  BROKEN    $1 -- no verdict"; fails=$((fails+1)); fi
  elif [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <mode> <literal old> <literal new>: exactly one match in blindrsa.go, or INERT.
mut() {
  python3 - "$SRC" "$3" "$4" <<'PY' || { inert "$1"; return; }
import sys
p,old,new=sys.argv[1:4]
s=open(p).read()
if s.count(old)!=1: sys.exit(1)
open(p,'w').write(s.replace(old,new))
PY
  [ "$2" = survive ] && rm -f "$KAT"
  conv "$1" "$2"
}
K1=(const\ saltLen\ =\ 48 const\ saltLen\ =\ 32)
K2=('SaltLength: saltLen' 'SaltLength: rsa.PSSSaltLengthAuto')
K3=('= 0x01' '= 0x02')
K4=('= 0xbc' '= 0xbd')
mut "K1 saltLen 48 -> 32" convict "${K1[@]}"
mut "K2 Verify accepts any salt length" convict "${K2[@]}"
mut "K3 PSS separator 0x01 -> 0x02" convict "${K3[@]}"
mut "K4 trailer 0xbc -> 0xbd" convict "${K4[@]}"
echo "-- K1 and K2 against the tests without blindrsa_kat_test.go (origin/main's):"
mut "K1 saltLen 48 -> 32" survive "${K1[@]}"
mut "K2 Verify accepts any salt length" survive "${K2[@]}"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not as required"; exit 1; }
