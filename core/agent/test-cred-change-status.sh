#!/usr/bin/env bash
# test-cred-change-status.sh [--mutate] -- runs cred_change_status_test.go (NWP-20261208-05: a passphrase change's
# session-scope outcome record, written by ROTATE and RECOVER, and the in-session issue report's cred_change* keys);
# --mutate re-runs it against a COPY of the package with each part broken in turn. Each mutant must be CONVICTED by a
# `--- FAIL` of the test named beside it; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 900s -run 'TestCredChange|TestEveryGoroutineGoesThroughGoSafe|TestNoLogPrintsAProfileNameOutsideQuotes' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement> <the test that must convict it>: apply to the copy, run the suite
# there, require that test's own `--- FAIL`, then restore the file.
mut() {
  local label="$1" f="$2" conv="$5" res
  cp "$P/$f" "$W/orig.go"
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p,encoding='utf-8').read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w',encoding='utf-8').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *"--- FAIL: $conv"* ]]; then echo "  convicted $label (by $conv)"
    else echo "  SURVIVED  $label (wanted --- FAIL: $conv)"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 the committed write is removed" main.go \
  '\twriteCredChange\(dest, rotateCredChange\(name, oldpass, newpass, "committed", credMarkerWord\(live, staleMarker\), kg, tc\)\)\n' '' \
  TestCredChangeRotateLive
mut "M2 a stale-marker repair is classified rekeyed" cred_change_status.go \
  'case live:\n\t\treturn "rekeyed"' 'case live || staleMarker:\n\t\treturn "rekeyed"' TestCredChangeRotateStale
mut "M3 the merge emits without the cur==new/old tie" cred_change_status.go \
  'if nowWord == "" \{\n\t\treturn\n\t\}' 'if nowWord == "" {\n\t\tnowWord = "matches"\n\t}' TestCredChangeScope
mut "M4 reverted is tested against the new digest" cred_change_status.go \
  'case rold != "-" && cur == rold:' 'case rold != "-" && cur == rnew:' TestCredChangeReverted
mut "M5 the deviceScope return is removed" cred_change_status.go \
  'if deviceScope \|\| status == nil \{' 'if status == nil {' TestCredChangeScope
mut "M6 the bind and inbox counts are swapped" cred_change_status.go \
  'r\.Bind, b01\(r\.BindErr\), r\.Inbox,' 'r.Inbox, b01(r.BindErr), r.Bind,' TestCredChangeRotateLive
mut "M7 recover writes old when matched != 1" cred_change_status.go \
  'if tc\.Matched == 1 \{' 'if tc.Matched >= 1 {' TestCredChangeRecover
mut "M8 the partial branch records path=committed" main.go \
  'rotateCredChange\(name, oldpass, newpass, "partial",' 'rotateCredChange(name, oldpass, newpass, "committed",' \
  TestCredChangePartial
mut "M9 the caller-value delete is removed" cred_change_status.go \
  '\tfor k := range status \{ // a nil map ranges zero times\n.*?\n\t\}\n' '' TestCredChangeScope
mut "M10 the forgetSessionKeys removal is removed" main.go \
  '\tremoveCredChange\(\) +// NWP-20261208-05[^\n]*\n' '' TestCredChangeSessionEnd
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
