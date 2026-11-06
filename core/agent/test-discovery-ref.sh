#!/usr/bin/env bash
# test-discovery-ref.sh [--mutate] -- runs the discovery tests (NWP-20261117-08: bootstrapRef is KDF-derived, with no
# lookup of the old sha256 form) and go vet; --mutate re-runs the tests against main.go with each property removed in
# turn, restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
SRC=main.go
trap '[ -f "$W/$SRC" ] && cp -f "$W/$SRC" "$SRC"; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='TestDisco|TestGatewayRoamsViaDiscovery'

vet=$(go vet ./... 2>&1) || { echo "$vet"; echo "FAIL: go vet"; exit 1; }
out=$(go test -count=1 -run "$RUN_RE" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/$SRC"
fails=0
mut() { # mut <label> <transform> <convicting test>...
  local label="$1" xf="$2" res want miss=""
  shift 2
  python3 - "$SRC" "$xf" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$SRC" "$SRC"; return; }
import sys
p, xf = sys.argv[1:3]
s = open(p).read()
def once(a, b, text):
    if text.count(a) != 1:
        sys.exit(1)
    return text.replace(a, b)
if xf == 'sha256form':
    s = once('\tmac := hmac.New(sha256.New, deriveKey(name, passphrase))\n'
             '\tmac.Write([]byte("nowhere-bootstrap-ref-v2"))\n'
             '\treturn hex.EncodeToString(mac.Sum(nil))\n',
             '\th := sha256.Sum256([]byte("nowhere-bootstrap-ref:" + name + "\\x00" + passphrase))\n'
             '\treturn hex.EncodeToString(h[:])\n', s)
elif xf == 'reuselabel':
    s = once('mac.Write([]byte("nowhere-bootstrap-ref-v2"))', 'mac.Write([]byte("nowhere-ref-v2"))', s)
elif xf == 'fallback':
    s = once('\tw := getRef(discoStore, bootstrapRef(name, pass))\n',
             '\tw := getRef(discoStore, bootstrapRef(name, pass))\n'
             '\tif w == "" {\n'
             '\t\th := sha256.Sum256([]byte("nowhere-bootstrap-ref:" + name + "\\x00" + pass))\n'
             '\t\tw = getRef(discoStore, hex.EncodeToString(h[:]))\n'
             '\t}\n', s)
elif xf == 'noforget':
    s = once('forgetSessionKeys("no store discovered")', '', s)
else:
    sys.exit(1)
open(p, 'w').write(s)
PY
  res=$(go test -count=1 -run "$RUN_RE" -v . 2>&1)
  if [[ "$res" == *"[build failed]"* ]]; then
    echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      [[ "$res" == *"--- FAIL: $want "* ]] || miss="$miss $want"
    done
    if [ -z "$miss" ]; then echo "  convicted $label"
    else echo "  SURVIVED  $label -- not failed by:$miss"; fails=$((fails+1)); fi
  fi
  cp -f "$W/$SRC" "$SRC"
}
mut "R1 the sha256 form restored" sha256form TestDiscoRefPublishedKeyIsKDFDerived TestDiscoRefLookupRequestsOnlyTheKDFKey \
  TestDiscoRefDistinctFromProfileRef TestDiscoRefOneArgon2PerProcess TestDiscoRefNoStoreMissForgetsTheKey
mut "R2 profileRefV2's label reused" reuselabel TestDiscoRefPublishedKeyIsKDFDerived TestDiscoRefDistinctFromProfileRef
mut "R3 a fallback GET of the old form" fallback TestDiscoRefLookupRequestsOnlyTheKDFKey
mut "R4 the NOSTORE forget removed" noforget TestDiscoRefNoStoreMissForgetsTheKey
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
