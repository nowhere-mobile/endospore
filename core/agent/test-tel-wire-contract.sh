#!/usr/bin/env bash
# test-tel-wire-contract.sh [--mutate] -- runs tel_wire_contract_test.go (NWP-20261022-11): the daemon's reader and
# formatter of the v2 SEAL-TEL wire held to testdata/tel-wire-v2.txt, the fixture the chooser's TelArrival is held to
# too (core/vendor-common/bin/test-tel-wire-java.sh); it also runs the PARTIAL tests of sealBoundArrival
# (TestV2Partial* in telephony_v2_test.go). --mutate re-runs it against a COPY of core/agent under a temp
# root, telephony_arrival.go and the reader broken in turn; the checked-out tree is never touched. Each mutant must be
# CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -run '^TestTelWire|^TestV2Partial' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

SRC=telephony_arrival.go
cp -a . "$W/agent"
fails=0
mut() { # mut <label> <file in the copy> <python-regex pattern> <replacement>
  local res
  cp -f "$SRC" "$W/agent/$SRC"
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
mut "G1 okArrivalReply drops the sealed count" $SRC '"OK %s %s %d%s\\n", vis, labelB64, sealed, tail' '"OK %s %s%s\\n", vis, labelB64, tail'
mut "G2 sealBoundArrival passes appended without the kick test" $SRC 'liveUID := ""\n\tif kick \{\n\t\tliveUID = appended\n\t\}' 'liveUID := appended'
mut "G3 readSealTelV2 swaps f[5] and f[6]" $SRC 'readArrivalHead\(f\[0\], f\[6\]\)(.*?)strconv\.ParseInt\(f\[5\]' 'readArrivalHead(f[0], f[5])\1strconv.ParseInt(f[6]'
mut "G4 From not passed through b64orEmpty" $SRC '(func readSealTelV2.*?)From: b64orEmpty\(f\[4\]\)' '\1From: f[4]'
mut "G5 sealBoundArrival never passes partial" $SRC 'stripped, kept > 0 && kept < len\(b\.Owners\), liveUID\)' 'stripped, false, liveUID)'
mut "G6 sealBoundArrival passes partial on every success" $SRC 'kept > 0 && kept < len\(b\.Owners\), liveUID\)' 'kept > 0 && kept <= len(b.Owners), liveUID)'
mut "G7 okArrivalReply writes PARTIAL after LIVE" $SRC '(\tif partial \{\n\t\ttail \+= " PARTIAL"\n\t\}\n)(\tif liveUID != "" \{\n\t\ttail \+= " LIVE " \+ liveUID\n\t\}\n)' '\2\1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
