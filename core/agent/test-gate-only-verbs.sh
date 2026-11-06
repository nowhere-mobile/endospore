#!/usr/bin/env bash
# test-gate-only-verbs.sh [--mutate] -- runs gate_only_verbs_test.go (NWP-20261024-04, NWP-20261031-12, NWP-20261118-15); --mutate
# re-runs it against owner_key.go and main.go with the gate-only rule of CLEAN-STORAGE, BOOT-SWEEP, BT-WIPE, ACK-REAP,
# CLEAR-COLDLOCK, CLAIM-COLDLOCK, GET-GATE-ALARM, OTA-APPLY, SET-OTA-AUTO, SET-OTA-TIME, SET-SYNC-INTERVAL and
# SEED-SSAID, EVICT-RECHECK-SAVED, SIGNIN-SHOWN (NWP-20261106-07), SET-DEVICE-LABEL (NWP-20261114-24), DROP-SSAID (NWP-20261115-01),
# GRANT-PERMS, PREFETCH-ARM, PREFETCH-DISARM, REKEY-ARM, REKEY-DISARM, REKEY-WAIT-WIFI, REKEY-WAIT-NET and
# REKEY-WAIT-BATTERY (NWP-20261118-15) broken in turn, restoring both files on exit. Each mutant must be
# CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
OK=owner_key.go
MAIN=main.go
RUN=(go test -count=1 -run '^TestGateOnly' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$OK" "$W/owner_key.go.orig"
cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/owner_key.go.orig" "$OK" 2>/dev/null; cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/owner_key.go.orig" "$OK"; cp "$W/main.go.orig" "$MAIN"; }
# conv <label>: run the suite against the mutated tree, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: TestGateOnly'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <file> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$2" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
CALL='\tif refusedGateOnlyCaller\(conn, name\) \{\n\t\treturn\n\t\}\n'
# The verb lists in the case line of gateOnlyCmd: drop one verb from it.
mut "G1 CLEAN-STORAGE dropped from the rule" "$OK" '(case )"CLEAN-STORAGE", ' '\1'
mut "G2 OTA-APPLY dropped from the rule" "$OK" '"GET-GATE-ALARM",\n\t\t"OTA-APPLY",' '"GET-GATE-ALARM",'
mut "G3 GET-GATE-ALARM dropped from the rule" "$OK" '"GET-GATE-ALARM",\n\t\t"OTA-APPLY",' '"OTA-APPLY",'
mut "G4 CLAIM-COLDLOCK dropped from the rule" "$OK" '"CLAIM-COLDLOCK", ("GET-GATE-ALARM")' '\1'
# The third case line: drop one new verb from it (G2 and G3 match the join of the second and third lines).
mut "G10 SET-OTA-AUTO dropped from the rule" "$OK" '"SIGNIN-SHOWN",\n\t\t"SET-OTA-AUTO", ' '"SIGNIN-SHOWN",\n\t\t'
mut "G11 SET-OTA-TIME dropped from the rule" "$OK" '"SET-OTA-AUTO", "SET-OTA-TIME", ' '"SET-OTA-AUTO", '
mut "G12 SET-SYNC-INTERVAL dropped from the rule" "$OK" '"SET-OTA-TIME", "SET-SYNC-INTERVAL", ' '"SET-OTA-TIME", '
mut "G13 SEED-SSAID dropped from the rule" "$OK" '"SET-SYNC-INTERVAL", "SEED-SSAID", ("EVICT-RECHECK-SAVED":)' '"SET-SYNC-INTERVAL", \1'
mut "G14 EVICT-RECHECK-SAVED dropped from the rule" "$OK" '"SEED-SSAID", "EVICT-RECHECK-SAVED":' '"SEED-SSAID":'
mut "G15 SIGNIN-SHOWN dropped from the rule" "$OK" '"OTA-APPLY", "SIGNIN-SHOWN",' '"OTA-APPLY",'
mut "G16 SET-DEVICE-LABEL dropped from the rule" "$OK" '"BOOT-SWEEP", "SET-DEVICE-LABEL", "BT-WIPE",' '"BOOT-SWEEP", "BT-WIPE",'
mut "G17 DROP-SSAID dropped from the rule" "$OK" '"ACK-REAP", "DROP-SSAID", ' '"ACK-REAP", '
# The second case clause (NWP-20261118-15): drop one verb from it.
mut "G18 GRANT-PERMS dropped from the rule" "$OK" '(case )"GRANT-PERMS", ' '\1'
mut "G19 PREFETCH-ARM dropped from the rule" "$OK" '"GRANT-PERMS", "PREFETCH-ARM", ' '"GRANT-PERMS", '
mut "G20 PREFETCH-DISARM dropped from the rule" "$OK" '"PREFETCH-ARM", "PREFETCH-DISARM",' '"PREFETCH-ARM",'
mut "G21 REKEY-ARM dropped from the rule" "$OK" '\t\t"REKEY-ARM", ' '\t\t'
mut "G22 REKEY-DISARM dropped from the rule" "$OK" '"REKEY-ARM", "REKEY-DISARM", ' '"REKEY-ARM", '
mut "G23 REKEY-WAIT-WIFI dropped from the rule" "$OK" '"REKEY-DISARM", "REKEY-WAIT-WIFI", ' '"REKEY-DISARM", '
mut "G24 REKEY-WAIT-NET dropped from the rule" "$OK" '"REKEY-WAIT-WIFI", "REKEY-WAIT-NET", ' '"REKEY-WAIT-WIFI", '
mut "G25 REKEY-WAIT-BATTERY dropped from the rule" "$OK" '"REKEY-WAIT-NET", "REKEY-WAIT-BATTERY":' '"REKEY-WAIT-NET":'
mut "G5 the ceiling raised past any roamed uid" "$MAIN" 'uid >= 0 && uid < 100000' 'uid >= 0 && uid < 10000000'
mut "G6 the failed-read refusal dropped" "$MAIN" 'return uid >= 0 && uid < 100000' 'return uid < 100000'
mut "G7 root refused" "$MAIN" 'uid >= 0 && uid < 100000' 'uid >= 1 && uid < 100000'
mut "G8 the check removed from handleLogin" "$MAIN" "$CALL" ''
mut "G9 the check moved after sessionMu" "$MAIN" "$CALL"'(.*?)(\tif name == "STATUS" \{)' '\1\tif refusedGateOnlyCaller(conn, name) {\n\t\treturn\n\t}\n\2'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
