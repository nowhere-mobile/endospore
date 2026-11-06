#!/usr/bin/env bash
# test-rollback-inbox.sh [--mutate] -- runs rollback_inbox_test.go (NWP-20261016-21); --mutate re-runs it against
# main.go / ProfileActivity.java with each part of the fix broken in turn, restoring the files on exit. Each mutant
# must be CONVICTED; one that fails to apply counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go; PA=../chooser/src/com/nowhere/chooser/ProfileActivity.java
RUN=(go test -count=1 -run 'TestRollbackInbox_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"; cp "$PA" "$PA.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"; mv -f "$PA.orig" "$PA"' EXIT
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  if "${RUN[@]}" >/dev/null 2>&1; then echo "  SURVIVED  $1"; fails=$((fails+1)); else echo "  convicted $1"; fi
  cp "$MAIN.orig" "$MAIN"; cp "$PA.orig" "$PA"
}
CALL='\t\tstageTelInboxForLiveSession\("s3", name, pass, uid, seFromHex\(seSecret\)\)\n'
mut "M1 the helper call removed" "$MAIN" "$CALL" ''
mut "M2 the helper called before the re-arm" "$MAIN" '(\t\trearmRoamSession\(dest, name, pass, uid, seSecret, "rollback failed, re-arm"\)[^\n]*\n)(.*?)'"$CALL" '\t\tstageTelInboxForLiveSession("s3", name, pass, uid, seFromHex(seSecret))\n\1\2'
mut "M3 the helper handed seFromSession(dest)" "$MAIN" 'stageTelInboxForLiveSession\("s3", name, pass, uid, seFromHex\(seSecret\)\)' 'stageTelInboxForLiveSession("s3", name, pass, uid, seFromSession(dest))'
mut "M4 the helper takes telMu around the store reads" "$MAIN" '(func stageTelInboxForLiveSession\([^\n]*\n)' '\1\ttelMu.Lock()\n\ttelMu.Unlock()\n'
mut "M5 the helper stages with no secret" "$MAIN" 'dk := openVaultDKSE\(v, name, pass, se\)\n\tif dk == nil \{\n\t\treturn\n\t\}\n\tif n, err := stageTelInboxLocked' 'dk := openVaultDKSE(v, name, pass, nil)\n\tif dk == nil {\n\t\treturn\n\t}\n\tif n, err := stageTelInboxLocked'
mut "M6 the helper overwrites instead of appending" "$MAIN" '(func stageTelInboxForLiveSession\([^\n]*\n)' '\1\tos.RemoveAll(telIngestBase)\n'
mut "M7 the call moved to the success branch" "$MAIN" "$CALL(.*?)(\tclearLocalSession\(dest\)\n)" '\1\t\tstageTelInboxForLiveSession("s3", name, pass, uid, seFromHex(seSecret))\n\2'
mut "M9 a transport panic no longer recovered in handleRollback" "$MAIN" '\t\t\tif r := recover\(\); r != nil \{\n\t\t\t\terr = recoveredErr\("rollback", r\)\n\t\t\t\}' '\t\t\tif r := recover(); r != nil {\n\t\t\t\tpanic(r)\n\t\t\t}'
mut "M10 the helper swallows its recover silently" "$MAIN" '(func stageTelInboxForLiveSession.*?)fmt\.Fprintf\(os\.Stderr, "\[logind\] %q user %s -> telephony hand-off skipped[^\n]*\n' '\1_ = r\n'
mut "M8 the chooser start removed" "$PA" '\n\s*try \{\n\s*startService\(new android\.content\.Intent\(this, CredentialService\.class\)\.putExtra\("telingest", true\)\);\n\s*\} catch \(Throwable t\) \{[^\n]*\n' '\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
