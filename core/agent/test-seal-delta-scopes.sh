#!/usr/bin/env bash
# test-seal-delta-scopes.sh [--mutate] -- NWP-20261113-08, backlog row "Your data's save copy says the wrong thing in four
# cases", case (2): recordSeal keeps the verdict's SCOPE lines (the guard picked as GET-LOGOFF-REFUSAL picks it) and
# SEAL-DELTA serves them as `scopes`. --mutate re-runs the tests against main.go / seal_delta.go / end_unsaved.go with
# each rule broken in turn, restoring all three on exit. Each mutant must be CONVICTED by a `--- FAIL`; one that fails
# to apply, or fails to compile, counts as a failure. Leaves nothing behind.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go seal_delta.go end_unsaved.go)
for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
trap 'for f in "${FILES[@]}"; do cp -f "$W/$f.orig" "$f" 2>/dev/null; done; rm -rf "$W"' EXIT
mkdir -p "$W/tmp" "$W/gotmp"
export TMPDIR="$W/tmp" GOTMPDIR="$W/gotmp"
RUN=(go test -count=1 -run 'TestSealDeltaScopes' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { local f; for f in "${FILES[@]}"; do cp "$W/$f.orig" "$f"; done; }
# conv <label>: run the suite against the mutated file, score it, then restore every file.
conv() {
  local res rc
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
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
mut "M1 the guard pick takes the first guard always" end_unsaved.go '(func refusalGuard\(rs \[\]string\) string \{.*?)if refusalReasonFinal\(x\) \{' '\1if x == rs[0] {'
mut "M2 the Scopes field is never filled" seal_delta.go 'r\.Scopes = sealScopes' '_ = sealScopes'
mut "M3 recordSeal does not clear it on OK" main.go '\tsealScopes = strings\.Join\(scopes, "\\n"\)' '\tif len(scopes) > 0 {\n\t\tsealScopes = strings.Join(scopes, "\\n")\n\t}'
mut "M4 resetSealSignals does not clear it" main.go '(func resetSealSignals\(\) \{.*?resetSealDeltaCaches\(\)\n)\tsealMu\.Lock\(\)\n\tsealScopes = ""[^\n]*\n\tsealMu\.Unlock\(\)\n' '\1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
