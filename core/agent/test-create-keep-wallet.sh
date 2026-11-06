#!/usr/bin/env bash
# test-create-keep-wallet.sh [--mutate] -- runs create_keep_wallet_test.go (NWP-20261014-28); --mutate re-runs it
# against main.go / telephony_inbox.go with each guard broken in turn, restoring the files on exit. Each mutant
# must be CONVICTED; one that fails to apply counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go; TI=telephony_inbox.go
RUN=(go test -count=1 -run 'TestCreateKeepWallet_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"; cp "$TI" "$TI.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"; mv -f "$TI.orig" "$TI"' EXIT
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  if "${RUN[@]}" >/dev/null 2>&1; then echo "  SURVIVED  $1"; fails=$((fails+1)); else echo "  convicted $1"; fi
  cp "$MAIN.orig" "$MAIN"; cp "$TI.orig" "$TI"
}
mut "M1 keepWallet ignored" "$TI" '!keepWallet \{\n\t\tremoveWallet' 'true {
		removeWallet'
mut "M2 the wallet-prefix skip removed" "$TI" ' \|\| strings\.HasPrefix\(e\.Name\(\), filepath\.Base\(wp\)\)' ''
mut "M3 live from roamSessionExists only" "$MAIN" 'live := roamSessionExists\(dest\) \|\| coldLockedUID\(dest\) != ""' 'live := roamSessionExists(dest)'
mut "M4 both branches wipe the wallet" "$MAIN" 'wipeSessionStateKeepWallet\(dest\)\n\t\} else' 'wipeSessionState(dest)
	} else'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
