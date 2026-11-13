#!/usr/bin/env bash
# test-shrink-forget.sh [--mutate] -- runs shrink_forget_test.go (NWP-20261129-07); --mutate re-runs it with the forget
# and its call sites broken in turn, restoring the files on exit. Each mutant must be CONVICTED with a --- FAIL; one that
# does not apply or does not compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestShrinkForget_' .)
FILES=(main.go shrink_intent.go roamsession_marker.go)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

restore() { local f; for f in "${FILES[@]}"; do cp -f "$W/$f" "$f"; done; }
for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
trap 'restore; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local o r
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
  o=$("${RUN[@]}" 2>&1); r=$?
  score_mutant "$1" "$r" "$o" || fails=$((fails+1))
  restore
}
mut "M1 handleRoamIn does not forget" main.go '\n\t\t// NWP-20261129-07:[^\n]*\n[^\n]*\n\t\tforgetShrinkIntents\(dest\)' ''
mut "M2 handleRoamInOffline does not forget" main.go '\n\t// NWP-20261129-07:[^\n]*\n\tforgetShrinkIntents\(dest\)' ''
mut "M3 the forget takes only deliberate markers" shrink_intent.go 'if !neutralizeShrinkMarker\(f\) \{\n\t\t\tstuck\+\+' 'if b, _ := os.ReadFile(f); !strings.HasPrefix(string(b), "deliberate") {
			continue
		}
		if !neutralizeShrinkMarker(f) {
			stuck++'
mut "M4 the forget removes the lock file" shrink_intent.go '\n\tif stuck == 0 \{\n\t\tshrinkDrop' '
	os.Remove(filepath.Join(dir, shrinkLockName))
	if stuck == 0 {
		shrinkDrop'
mut "M5 a RESUME forgets" main.go '\tclaimLocGlobalsAsync\(dest, uid, "resume"\)' '	forgetShrinkIntents(dest)
	claimLocGlobalsAsync(dest, uid, "resume")'
mut "M6 markRoamSession forgets" roamsession_marker.go '(func markRoamSession\(dest, name, pass, uid, seSecret string\) error \{\n)' '\1	forgetShrinkIntents(dest)
'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
