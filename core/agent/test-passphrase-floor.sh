#!/usr/bin/env bash
# test-passphrase-floor.sh [--mutate] -- runs the typed-passphrase floor tests (NWP-20261102-02, NWP-20261116-07); --mutate re-runs
# them against passphrase.go with the floor broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure. F5-F7
# (NWP-20261116-16, dn-1107 #5) break the whitespace collapse that the length is counted on.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=passphrase.go
RUN=(go test -count=1 -run 'TestPassphraseFloor|TestPassphraseRejectsName|TestGeneratePassphrase' .)

W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp "$SRC" "$W/passphrase.go.orig"
trap 'cp -f "$W/passphrase.go.orig" "$SRC" 2>/dev/null; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
restore() { cp "$W/passphrase.go.orig" "$SRC"; }
# conv <label>: run the suite against the mutated file, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: Test'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$SRC" "$2" "$3" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
# mut2 <label> <pat1> <rep1> <pat2> <rep2>: two edits, each pattern exactly once, or INERT.
mut2() {
  python3 - "$SRC" "$2" "$3" "$4" "$5" <<'PY' || { inert "$1"; return; }
import re,sys
p=sys.argv[1]
s=open(p).read()
for pat,rep in ((sys.argv[2],sys.argv[3]),(sys.argv[4],sys.argv[5])):
    n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
    if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
    s=n
open(p,'w').write(s)
PY
  conv "$1"
}
mut "F1 the word-count escape restored" 'if len\(runes\) < floorMinChars \{' 'if len(runes) < floorMinChars && len(words) < floorMinWords {'
mut "F2 the distinct check back under the length condition" 'if len\(words\) >= floorMinWords && distinctCount' 'if len(runes) < floorMinChars && distinctCount'
mut "F3 the old length reason" '"too short — use at least 12 characters"' '"too short — use at least 12 characters, or 4 words"'
mut "F4 the old distinct-words number" '"use at least 3 different words"' '"use at least 4 different words"'
mut "F5 the repeated-unit check removed" 'if repeatsAUnit\(condensed\) \{' 'if false && repeatsAUnit(condensed) {'
mut "F6 the period bound narrowed to one rune" 'for p := 1; p <= n/2; p\+\+ \{' 'for p := 1; p <= 1 && p <= n/2; p++ {'
mut "F7 the period bound off by one" 'for p := 1; p <= n/2; p\+\+ \{' 'for p := 1; p < n/2; p++ {'
mut "F8 whole repetitions only" 'for p := 1; p <= n/2; p\+\+ \{' 'for p := 1; p <= n/2; p++ { if n%p != 0 { continue }'
mut "F9 the repeated-unit check reads low" 'if repeatsAUnit\(condensed\) \{' 'if repeatsAUnit(low) {'
mut "F10 the repeated-unit reason changed" 'repeatsAUnit\(condensed\) \{\s+return false, "too repetitive' 'repeatsAUnit(condensed) { return false, "too repetitive, add more variety'
RUNES='runes := \[\]rune\(strings\.Join\(words, " "\)\)'
mut "F11 the count back on the raw input" "$RUNES" 'runes := []rune(pass)'
mut2 "F12 a collapse that keeps the ends" '"os"\n' '"os"
	"regexp"
' "$RUNES" 'runes := []rune(regexp.MustCompile(`\s+`).ReplaceAllString(pass, " "))'
mut "F13 spaces only, not tabs" "$RUNES" 'runes := []rune(strings.Join(strings.Fields(strings.ReplaceAll(pass, "\t", "x")), " "))'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
