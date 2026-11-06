#!/usr/bin/env bash
# test-seal-unresolved-session.sh [--mutate] -- runs seal_unresolved_session_test.go plus the two existing seal
# tests it must not change (NWP-20261019-05); --mutate re-runs them against main.go with each guard broken in turn,
# restoring the file on exit. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply or to compile
# counts as a failure, never a pass.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
PAT='TestThrowawaySealCreatesNoProfile|TestLostHeadWithBareReceiptRecovers|TestLiveProfileWithBareReceiptCreatesScope|TestScopeCreatedOnReceiptAloneWithBareHeadGone|TestTiedElsewhereWritesNoScopeHead|TestTiedProfileThatOpensHereCreatesScopeWithoutReceipt|TestNoStateDirKeepsTodaysBehaviour|TestRotatedSessionRecoversLostHead|TestRotatedSessionWithoutReceiptCreatesNoHead|TestSealRecoversLostHead|TestScopeSealLazyCreatesOnLiveProfile|TestScopedLoginDoesNotLiftTheFence|TestAScopeThatCannotBeRePointedPublishesNothing|TestSealBlindPkgs_SurviveTheLaterPushesOfTheSameOut'
RUN=(go test -count=1 -run "$PAT" .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$MAIN.orig" "$MAIN"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  case "$res" in
    *'--- FAIL'*) echo "  convicted $1" ;;
    *) echo "  SURVIVED  $1 (no --- FAIL; a compile error is not a conviction)"; fails=$((fails+1)) ;;
  esac
  cp "$MAIN.orig" "$MAIN"
}
mut "M1 bare-arm check removed" '\t\tif !sessionHoldsBareReceipt\(profile, pass\) \{\n\t\t\tfmt\.Printf\(noResolvedSessionSeal, logProfile\(profile\)\)\n\t\t\treturn\n\t\t\}\n' ''
mut "M2 scope-arm check removed" '&& !scopeHeadMayBeCreated\(base, profile, pass\)' '&& false'
mut "M3 open-head branch removed" '\treturn head != "" && !locked\n\}' '	return head == "\\x00" && !locked
}'
mut "M4 the locked term dropped" '\treturn head != "" && !locked\n\}' '	return head != "" && (!locked || head != "")
}'
mut "M5 helper reads the scope receipt" 'bare = profile\[:i\]\n\t\}\n\treturn haveRestoreReceipt' 'bare = profile
	}
	return haveRestoreReceipt'
mut "M6 receipts-off escape inverted" 'if restoreReceiptDir\(\) == "" \{\n\t\treturn true' 'if restoreReceiptDir() != "" {
		return true'
mut "M7 rotation does not move the bare receipt" '\t\twriteRestoreReceipt\(profileRefV2\(scoped, newpass\), head\)\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
