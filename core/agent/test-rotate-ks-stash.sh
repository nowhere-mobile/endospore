#!/usr/bin/env bash
# test-rotate-ks-stash.sh [--mutate] -- runs rotate_ks_stash_test.go (NWP-20261019-29); --mutate re-runs it against
# main.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED (a failing
# test, not a compile error); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestRotateRekeysTheKeystorePushStash|TestRotateLeavesAnother|TestRotateWithoutAStash|TestRefusedKeyguardRekey|TestRejectedRotationLeavesTheStash|TestPartialRetireRekeysTheStash|TestRotateLeavesAMalformed|TestRotatedStashIsPrivate' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <repl>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$MAIN.orig" "$MAIN"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED/NOT-COMPILED $1"; fails=$((fails+1)); fi
  cp "$MAIN.orig" "$MAIN"
}
mut "M1 success-path call removed" '(\t// The rotation committed: carry[^\n]*\n\tcarryTelephonyRef[^\n]*\n)\trekeyKsLogoffCreds\(dest, name, oldpass, newpass\)\n' '\1'
mut "M2 RetireBegun call removed" '(\t\t\tcarryTelephonyRef[^\n]*\n)\t\t\trekeyKsLogoffCreds\(dest, name, oldpass, newpass\)\n' '\1'
mut "M3 match on name only" 'lines\[0\] != name \|\| lines\[1\] != oldpass' 'lines[0] != name'
mut "M4 call at the top of the err block" '(\tif err != nil \{\n)(\t\t// NWP-20260915-14: DID IT PARTLY)' '\1\t\trekeyKsLogoffCreds(dest, name, oldpass, newpass)\n\2'
mut "M5 lines 3-4 dropped" 'rewriteKsStash\(path, \[\]byte\(strings\.Join\(lines, "\\n"\)\)\)' 'rewriteKsStash(path, []byte(strings.Join(lines[:2], "\\n")+"\\n"))'
mut "M6 absent file created" 'if err != nil \{\n\t\treturn\n\t\}\n\t// Exactly' 'if err != nil {\n\t\traw = []byte(name + "\\n" + oldpass + "\\n10\\n\\n")\n\t}\n\t// Exactly'
mut "M7 any four-or-more-line shape accepted" 'len\(lines\) != 5 \|\| lines\[4\] != "" \|\| ' 'len(lines) < 4 || '
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
