#!/usr/bin/env bash
# test-gateway-prop.sh [--mutate] -- runs gateway_prop_test.go (NWP-20261204-08: the login daemon republishes
# nowhere.gateway_url, NowherePush's gateway, after each runtime change to GATEWAY_URL); --mutate re-runs it against
# copies of main.go with each guard broken in turn, injected with `go test -overlay`, so the source tree is never
# edited. Each mutant names the test that convicts it and must be CONVICTED by a real `--- FAIL`; one that does not
# apply, does not compile, or dies without a FAIL line counts as a failure.
#   A1 applyManagedStore no longer republishes                 TestGatewayPropRepublishedOnManagedEnrol
#   A2 applyGateway no longer republishes                      TestGatewayPropRepublishedOnDiscovery, ...ClearFallsBackToDefault
#   A3 the property is persist.nowhere.gateway_url             TestGatewayPropName
#   A4 republish publishes defaultGatewayURL                   TestGatewayPropRepublishedOnManagedEnrol
#   A5 the empty guard removed                                 TestGatewayPropSkipsEmptyAndTooLong
#   A6 the length bound off by one (> 92)                      TestGatewayPropSkipsEmptyAndTooLong
#   A7 applyGateway publishes its raw argument                 TestGatewayPropClearFallsBackToDefault
#   A8 applyManagedStore republishes under s3InitMu            TestGatewayPropNotUnderTheStoreLock
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=main.go
PAT='TestGatewayProp'

out=$(go test -count=1 -run "$PAT" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <test regex that must convict> <python-regex pattern> <replacement>
  local label="$1" tests="$2" m ov out rc
  m=$(mktemp -p "$W" mut.XXXXXX.go) || { fails=$((fails+1)); return; }
  ov=$(mktemp -p "$W" overlay.XXXXXX.json) || { fails=$((fails+1)); return; }
  python3 - "$SRC" "$m" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst,pat,rep=sys.argv[1:5]
s=open(src).read()
n,c=re.subn(pat,rep,s,flags=re.S)
if c!=1: sys.exit(1)
open(dst,'w').write(n)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$SRC" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$(go test -count=1 -overlay "$ov" -run "$tests" . 2>&1); rc=$?
  score_mutant "$label ($tests)" "$rc" "$out" || fails=$((fails+1))
}
mut "A1 applyManagedStore no longer republishes" 'TestGatewayPropRepublishedOnManagedEnrol$' \
  '(\ts3InitMu\.Unlock\(\)\n)\trepublishGatewayProp\(\) // after the unlock[^\n]*\n' '\1'
mut "A2 applyGateway no longer republishes" 'TestGatewayProp(RepublishedOnDiscovery|ClearFallsBackToDefault)$' \
  '\trepublishGatewayProp\(\) // before the persist[^\n]*\n' ''
mut "A3 the property is persist.nowhere.gateway_url" 'TestGatewayPropName$' \
  'const gatewayProp = "nowhere\.gateway_url"' 'const gatewayProp = "persist.nowhere.gateway_url"'
mut "A4 republish publishes defaultGatewayURL" 'TestGatewayPropRepublishedOnManagedEnrol$' \
  '\tv := issueGatewayURL\(\)\n' '\tv := defaultGatewayURL\n'
mut "A5 the empty guard removed" 'TestGatewayPropSkipsEmptyAndTooLong$' \
  '(\tv := issueGatewayURL\(\)\n)\tif v == "" \{\n\t\treturn\n\t\}\n' '\1'
mut "A6 the length bound off by one" 'TestGatewayPropSkipsEmptyAndTooLong$' \
  'if len\(v\) >= 92 \{' 'if len(v) > 92 {'
mut "A7 applyGateway publishes its raw argument" 'TestGatewayPropClearFallsBackToDefault$' \
  '\trepublishGatewayProp\(\) // before the persist' '\tpublishGatewayProp(url) // before the persist'
mut "A8 applyManagedStore republishes under s3InitMu" 'TestGatewayPropNotUnderTheStoreLock$' \
  '\ts3InitMu\.Unlock\(\)\n\trepublishGatewayProp\(\) // after the unlock[^\n]*\n' '\trepublishGatewayProp()\n\ts3InitMu.Unlock()\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
