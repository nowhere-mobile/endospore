#!/usr/bin/env bash
# test-coldlock-signout-bar.sh [--mutate] -- runs coldlock_signout_bar_test.go (NWP-20261111-09, Q067) with the
# arm-fail tests it must not break; --mutate re-runs them against main.go with each part of the sign-out bar broken in
# turn, restoring the file on exit. Each mutant must be CONVICTED (a real `--- FAIL`); one that fails to apply, or
# fails to compile, counts as a failure. M6 and M7 are convicted by the source checks in the Go file
# (TestColdLockSignOutBarClaimSharesTheHold, TestColdLockSignOutBarArmFailClearSource): the driven B7 races the defer.
# M8 (NWP-20261125-20) drops the bar on every revoke and removes the declined branch's re-raise; only
# TestColdLockSignOutBarRefusesDuringADeclinedRevokeRequeue convicts it. Its first edit alone survives (the re-raise
# covers it).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'SignOutBar|ColdLockArmFail' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local mout mrc
  mout=$("${RUN[@]}" 2>&1); mrc=$?
  if [ $mrc -ne 0 ] && [[ "$mout" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1 (rc=$mrc, no --- FAIL)"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "M1 handleLogout ignores the bar" \
  'if coldLockSignOutBar == uid \{(\n\t\tcoldLockMu\.Unlock\(\)\n\t\tfmt\.Fprint\(conn, "BUSY COLDLOCK)' \
  'if false && coldLockSignOutBar == uid {\1'
mut "M2 the key-bound set removed" \
  "(\t\t\tqueueIdleRearm\(uid\) // Q067: as Check A's logoff arm[^\n]*\n\t\t\treturn true\n\t\t\}\n)\t\tcoldLockSignOutBar = uid\n" \
  '\1'
mut "M3 the Check B set removed" \
  '\tif !revoke \{\n\t\tcoldLockSignOutBar = uid\n\t\}\n' \
  ''
mut "M4 the deferred clear removed" \
  '(\tdefer func\(\) \{\n\t\tcoldLockMu\.Lock\(\)\n\t\tif coldLockSignOutBar == uid \{\n)\t\t\tcoldLockSignOutBar = ""\n' \
  '\1'
mut "M5 the pre-rekey logoff check removed" \
  '(\t\tcoldLockMu\.Lock\(\)\n\t\t)if logoffInFlight\(uid\) \{(\n\t\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] cold-lock ABORTED before the key-bound rekey)' \
  '\1if false {\2'
mut "M6 the claim moved back outside coldLockMu" \
  '\t(logoffClaim := setLogoffInFlight\(uid\)[^\n]*)\n(.*?\tsealRunKind, sealRunAt = "logoff", time\.Now\(\)[^\n]*\n)' \
  '\2\t\1\n'
mut "M7 the arm-fail clear removed" \
  '(\t\tcoldLockRevoking = true\n(?:\t\t//[^\n]*\n)*)\t\tcoldLockSignOutBar = ""\n' \
  '\1'
mut "M8 a revoke drops the bar and the declined re-raise removed" \
  '(\tif !revoke \{\n\t\tcoldLockSignOutBar = uid\n\t\})(\n.*?cold-lock abort DECLINED for user %s: rekey unwind failed[^\n]*\n[^\n]*\n\t\t\trevoke = false\n\t\t\tcoldLockMu\.Lock\(\)\n\t\t\tcoldLockRevoking = false[^\n]*\n)\t\t\tcoldLockSignOutBar = uid[^\n]*\n' \
  '\1 else {\n\t\tcoldLockSignOutBar = ""\n\t}\2'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
