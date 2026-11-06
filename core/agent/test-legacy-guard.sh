#!/usr/bin/env bash
# test-legacy-guard.sh [--mutate] -- runs legacy_guard_test.go (NWP-20261019-16); --mutate re-runs it against main.go
# with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestLegacyLogoff(Refused|Proceeds)|TestLegacyLoginFallthroughRefused' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -8
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  cp "$MAIN.orig" "$MAIN"
}
mut "M1 LOGOFF roamed guard removed" 'if roamSessionExists\(dest\) \{\n\t\treturn "roamed session live"' 'if false {
		return "roamed session live"'
mut "M2 LOGOFF parked guard removed" 'uid := coldLockedUID\(dest\); uid != "" && !androidUserGone\(uid\) \{\n\t\treturn "cold-locked' 'uid := coldLockedUID(dest); false && uid != "" {
		return "cold-locked'
mut "M3 fallthrough parked guard removed" 'if uid := coldLockedUID\(dest\); uid != "" && !androidUserGone\(uid\) \{\n\t\tfmt.Fprintf\(os.Stderr, "\[logind\] legacy login refused' 'if uid := coldLockedUID(dest); false && uid != "" {
		fmt.Fprintf(os.Stderr, "[logind] legacy login refused'
mut "M4 gone-user exception removed" 'uid != "" && !androidUserGone\(uid\) \{\n\t\treturn "cold-locked' 'uid != "" {
		return "cold-locked'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
