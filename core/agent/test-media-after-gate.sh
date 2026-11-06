#!/usr/bin/env bash
# test-media-after-gate.sh [--mutate] -- runs media_after_gate_test.go (NWP-20261123-07, backlog "A 179-second login,
# 95% of it bulk media restored INLINE before the gate opens", Q106 slice S1: bgSplit, docs/media-after-gate.md §2 and
# §3) with TestEssSpan; --mutate re-runs them against a COPY of the package with one rule of bgSplit broken in turn.
# Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestBgSplit|TestEssSpan' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
mut() {
  local label="$1" f="$2" res rc
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 the .nomedia rule is dropped" media_after_gate.go \
  ' \|\| path\.Base\(rel\) == "\.nomedia"' ' || path.Base(rel) == ""'
mut "M2 the mediaDeferForbidden rule is dropped" media_after_gate.go \
  ' \|\| mediaDeferForbidden\(rel\)' ''
mut "M3 preGate removes by hash instead of by index" media_after_gate.go \
  '\t\tif !drop\[i\] \{' \
  '\t\tif _ = i; !func() bool { for j, x := range m.Chunks { if drop[j] && x == h { return true } }; return false }() {'
mut "M4 the bad-span check is dropped" media_after_gate.go \
  ' \|\| !valid\(r\) \{' ' || (false && !valid(r)) {'
mut "M5 the no-index guard is dropped" media_after_gate.go \
  'if !m\.EssIdx \|\| len\(m\.Ess\) == 0 \{' 'if false {'
mut "M6 a bad span does not count in the overlap check (RF-001)" media_after_gate.go \
  '\tfor _, r := range m\.Ess \{\n\t\tlo, hi :=' '\tfor _, r := range m.Ess {\n\t\tif !valid(r) {\n\t\t\tcontinue\n\t\t}\n\t\tlo, hi :='
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
