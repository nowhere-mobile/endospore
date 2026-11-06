#!/usr/bin/env bash
# test-wifi-store-quotes.sh [--mutate] -- NWP-20261031-09: the daemon-side Wi-Fi capture (parseWifiStore) strips ONE
# quote pair and refuses a tab, a newline, a blank SSID and an over-long line, as the chooser's WifiMirrorLine.encode
# does. Plain: the parseWifiStore tests. --mutate applies each mutant to wifi_store.go (the pristine copy lives in one
# temp root, restored after every mutant and on exit); each must be CONVICTED by a `--- FAIL`. A mutant that fails to
# apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=wifi_store.go
trap 'cp -f "$W/$F" "$F" 2>/dev/null; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
cp "$F" "$W/$F"

out=$(go test -count=1 -run 'TestParseWifiStore' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <old-literal> <new-literal>
mut() {
  local label="$1" old="$2" new="$3" res
  if ! python3 - "$F" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F" "$F"; return; fi
  res=$(go test -count=1 -run 'TestParseWifiStore' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: TestParseWifiStoreQuotesAndTabs'* ]]; then echo "  convicted $label"
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$F" "$F"
}
mut "M1 the SSID unquote back to strings.Trim" 's, ok := unquoteOnce(ssid)' 's, ok := strings.Trim(ssid, "\""), ssid != ""'
mut "M2 the PSK unquote back to strings.Trim" 'if p, ok = unquoteOnce(psk); !ok {' 'if p, ok = strings.Trim(psk, "\""), true; !ok {'
mut "M3 the PSK tab check removed" 'strings.ContainsAny(p, "\t\n")' 'strings.ContainsAny(p, "\n")'
mut "M4 the SSID trim()-blank check reduced to == \"\"" 'javaBlank(s) ||' 's == "" ||'
mut "M5 the 256-byte cap removed" 'if n > 256 {' 'if n > 1<<30 {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
