#!/usr/bin/env bash
# test-ota-signin-refusal.sh [--mutate] -- runs ota_signin_refusal_test.go (NWP-20261101-11, Q062); --mutate re-runs it
# against main.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# `--- FAIL`; one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
MAIN=main.go
RUN=(go test -count=1 -run 'OtaSigninRefusal' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || { rm -rf "$W"; exit 1; }
[ "${1:-}" = --mutate ] || { rm -rf "$W"; exit 0; }

cp "$MAIN" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <repl>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$W/main.go.orig" "$MAIN"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED/NOT-COMPILED $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
CALL='\tif refuseSignInDuringOta\(conn, dest\) \{[^\n]*\n\t\treturn\n\t\}\n'
mut "O1 otaInFlight ignores APPLYING" '(return strings\.HasPrefix\(s, "DOWNLOADING"\)) \|\| strings\.HasPrefix\(s, "APPLYING"\)' '\1'
mut "O2 handleRoamIn call removed" '(func handleRoamIn\(conn[^\n]*\n\t//[^\n]*\n\tdropSigninFail\(dest\)\n)'"$CALL" '\1'
mut "O3 call moved after handleRoamIn NOSTORE check" '(func handleRoamIn\(conn[^\n]*\n\t//[^\n]*\n\tdropSigninFail\(dest\)\n)'"$CALL"'(.*?\t\tfmt\.Fprint\(conn, "NOSTORE\\n"\)[^\n]*\n\t\treturn\n\t\}\n)' '\1\2\tif refuseSignInDuringOta(conn, dest) {\n\t\treturn\n\t}\n'
mut "O4 handleResume refuses too" '(func handleResume\(conn net\.Conn, dest, entry string\) \{\n)' '\1\tif refuseSignInDuringOta(conn, dest) {\n\t\treturn\n\t}\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
