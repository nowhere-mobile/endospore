#!/usr/bin/env bash
# test-end-unsaved-strict-read.sh [--mutate] -- runs end_unsaved_strict_read_test.go and the END-UNSAVED tests
# (NWP-20261201-27, h60 #16: END-UNSAVED and RESTART-UNSAVED read the stored wallet strictly before their publish);
# --mutate re-runs them against a COPY of the package with the change broken in turn (the work tree is never edited).
# Each mutant must be CONVICTED by a `--- FAIL` of the test it names; one that fails to apply, or fails to compile,
# counts as a failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
SRC=$PWD
PAT='TestEndUnsavedStrictRead_|TestEndUnsaved_'

out=$(go test -count=1 -run "$PAT" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <test that convicts it> <python expression over s, None when it does not apply>: the expression
# runs on a fresh copy. The package sits at $d/agent with every sibling of core/agent linked beside it, because a test
# of this run reads ../chooser: in a bare copy that test fails for every mutant, which would convict them all.
mut() {
  local label="$1" file="$2" test="$3" expr="$4" d res mrc sib
  d=$(mktemp -d -p "$W") || exit 2
  mkdir "$d/agent" || exit 2
  cp -r "$SRC/." "$d/agent/"
  for sib in "$SRC"/../*; do
    [ "$(basename "$sib")" = agent ] || ln -s "$(cd "$sib" && pwd)" "$d/$(basename "$sib")"
  done
  if ! python3 - "$d/agent/$file" "$expr" <<'PY'
import re,sys
p,expr=sys.argv[1:3]
s=open(p).read()
n=eval(expr)
if n is None or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; fi
  res=$(cd "$d/agent" && go test -count=1 -run "$PAT" . 2>&1); mrc=$?
  if [[ "$res" == *"--- FAIL: $test"* ]]; then echo "  convicted $label ($test)"
  elif ! score_mutant "$label" "$mrc" "$res"; then fails=$((fails+1))
  else echo "  WRONG TEST $label -- $test did not fail; last lines:"; tail -n 15 <<<"$res"; fails=$((fails+1)); fi
  rm -rf "$d"
}

ARM='\t\t} else if errors.Is(err, errEndWalletUnreadable) {\n'
STRANDED='\t\t} else if errors.Is(err, errWalletNoSlot) && final && r.stranded() {\n'
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn(r'''$1''', $2, s))"; }
CREDIT='(\t\t\tcreditLost = true\n)(\t\t\} else if errors\.Is\(err, errWalletNoSlot\))'

mut "M1 the read call removed from the publish" end_unsaved.go TestEndUnsavedStrictRead_PublishesNothingOverAnUnreadableCopy \
  "$(one '\tif !endStoredWalletRead\(name, pass, func\(\) \[\]byte \{ return dk \}\) \{\n\t\treturn errEndWalletUnreadable\n\t\}\n' "''")"
mut "M2 the END-UNSAVED arm removed" end_unsaved.go TestEndUnsavedStrictRead_EndUnsavedWarnsAndKeepsTheFile \
  "(lambda i, j: s[:i] + s[j:] if -1 < i < j else None)(s.find('$ARM'), s.find('$STRANDED'))"
mut "M3 the END-UNSAVED arm does not set creditLost" end_unsaved.go TestEndUnsavedStrictRead_EndUnsavedWarnsAndKeepsTheFile \
  "$(one "$CREDIT" "lambda m: m.group(2)")"
mut "M4 the END-UNSAVED arm sets walletSaved" end_unsaved.go TestEndUnsavedStrictRead_EndUnsavedWarnsAndKeepsTheFile \
  "$(one "$CREDIT" "lambda m: m.group(1) + '\t\t\twalletSaved = true\n' + m.group(2)")"
mut "M5 the RESTART-UNSAVED arm removed" end_unsaved.go TestEndUnsavedStrictRead_RestartUnsavedWarns \
  "(lambda i, j: s[:i] + s[j:] if -1 < i < j else None)(s.rfind('$ARM'), s.rfind('\t\t} else if err != nil {\n'))"
mut "M6 one try, not two" signout_strict_read.go TestEndUnsavedStrictRead_TwoFailedTriesAreUnreadable \
  "$(one 'try < 2' "'try < 1'")"
mut "M7 the select replaced by an unbounded wait" signout_strict_read.go TestEndUnsavedStrictRead_TheBoundEndsAStuckRead \
  "$(one '\tselect \{\n\tcase ok := <-res:\n\t\treturn ok\n\tcase <-time\.After\(endStoredWalletReadWait\):\n\t\treturn false\n\t\}\n' "'\treturn <-res\n'")"

[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
