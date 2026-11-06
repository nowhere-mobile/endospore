#!/usr/bin/env bash
# test-end-unsaved-push.sh [--mutate] -- runs the push-licence cases (end_unsaved_push_test.go; NWP-20261101-05, Q070):
# two sign-outs in a row that could not reach the store license END-UNSAVED with no wallet publish, and
# GET-LOGOFF-REFUSAL gains a PUSH line. --mutate re-runs them against end_unsaved.go / main.go with each guard broken
# in turn, restoring both files on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or
# to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
EU=end_unsaved.go
MN=main.go
trap 'for f in "$EU" "$MN"; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'EndUnsavedPush|GetLogoffRefusal_PushLine|VerdictSavedAny' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$EU" "$W/$EU.orig"
cp "$MN" "$W/$MN.orig"
fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 res
  python3 - "$file" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$file.orig" "$file"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -qE 'build failed|\[setup failed\]' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$file.orig" "$file"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
mut "U1 the licence at 1" "$EU" "$(one "r'const endUnsavedPushAfter = 2'" "'const endUnsavedPushAfter = 1'")"
mut "U2 recordSeal never resets the run" "$MN" "$(one "r'\tif verdictSavedAny\(out\) \{\n\t\tresetPushStuck\(\)[^\n]*\n\t\}\n'" "''")"
mut "U3 the push-licensed end calls endUnsavedWallet" "$EU" "$(one "r'\t\} else if !profileGoneNow\(r, name, pass\) \{'" "'\t}\n\tif !profileGoneNow(r, name, pass) {'")"
mut "U4 the PUSH line never written" "$EU" "$(one "r'\tif push > 0 \{'" "'\tif false && push > 0 {'")"
mut "U5 NONE when only push > 0" "$EU" "$(one "r'r == nil && media == 0 && push == 0'" "'r == nil && media == 0'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
