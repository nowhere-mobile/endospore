#!/usr/bin/env bash
# test-direct-bracket.sh [--mutate] -- runs direct_bracket_test.go (NWP-20261029-02); --mutate re-runs it against
# billing.go / main.go with each direct-mode bracket removed in turn (the body kept, run inline), restoring both on
# exit. Each mutant must be CONVICTED (a `--- FAIL`); one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
BILL=billing.go
MAIN=main.go
RUN=(go test -count=1 -run 'TestDirect(SealWallet|SealWalletValueDurable|LegacyLogoff)_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$BILL" "$W/billing.go.orig"
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/billing.go.orig" "$BILL"; cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <file> <python-regex whose group 1 precedes the capWrite( call to replace>
  local label="$1" file="$2" pat="$3" mout mrc
  python3 - "$file" "$pat" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat=sys.argv[1:3]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.group(1)+'directBracketMutantInline(func() {',s,count=1,flags=re.S)
if c!=1: sys.exit(1)
n+='\n// mutant shim: the body runs inline, with no bracket\nfunc directBracketMutantInline(fn func()) { fn() }\n'
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1); mrc=$?
  if [ "$mrc" -ne 0 ] && [[ "$mout" == *'--- FAIL'* ]]; then echo "  convicted $label"
  else echo "  SURVIVED  $label (rc=$mrc, no --- FAIL)"; fails=$((fails+1)); fi
  cp -f "$W/billing.go.orig" "$BILL"
  cp -f "$W/main.go.orig" "$MAIN"
}
mut "D1 sealWallet's bracket removed" "$BILL" '(\nfunc sealWallet\(.*?)capWrite\(name, pass, dk, func\(\) \{'
mut "D2 sealWalletValueDurable's direct-arm bracket removed" "$BILL" '(\nfunc sealWalletValueDurable\(.*?if !capMode\(\) \{.*?)capWrite\(name, pass, dk, func\(\) \{'
mut "D3 the legacy LOGOFF's bracket removed" "$MAIN" '(\nfunc handleLogoff\(.*?)capWrite\(name, pass, nil, func\(\) \{'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
