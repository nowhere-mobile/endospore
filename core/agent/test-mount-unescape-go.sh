#!/usr/bin/env bash
# test-mount-unescape-go.sh [--mutate] -- runs the seal's mount-table unescape tests (NWP-20261128-41): unescapeMountPath
# decodes /proc/self/mounts' \040 \011 \012 \134 in one left-to-right pass, and parseMediaOverlayUndersPub keys an
# overlay with a space, a tab or a literal "\040" in its name by its REAL path, through its .under bind or mediad's
# published map. The Go half of core/vendor-common/prebuilts/test-mount-unescape.sh. --mutate edits media_seal.go IN
# PLACE, one mutant at a time, each from a pristine copy; the one EXIT trap puts the pristine file back. Each mutant
# must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
cp media_seal.go "$W/media_seal.go.pristine" || { rm -rf "$W"; exit 2; }
trap 'cp "$W/media_seal.go.pristine" media_seal.go; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestUnescapeMountPath|TestParseUnders' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 expr=$2 res mrc
  cp "$W/media_seal.go.pristine" media_seal.go || { fails=$((fails+1)); return; }
  if ! python3 - media_seal.go "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  cp "$W/media_seal.go.pristine" media_seal.go || fails=$((fails+1))
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
# M3's pre-pass goes after the early return of unescapeMountPath, before its loop.
PREPASS_AT='func unescapeMountPath(s string) string {\n\tif !strings.Contains(s, `\\`) {\n\t\treturn s\n\t}\n'
PREPASS='\ts = strings.ReplaceAll(s, `\\134`, `\\`)\n'
mut "M1 the 040 (space) case deleted" \
  "$(one "r'\t\t\tcase \"040\":\n\t\t\t\tb\.WriteByte\(\' \'\)\n\t\t\t\ti \+= 3\n\t\t\t\tcontinue\n'" "''")"
mut "M2 i+4 < len(s): an escape in the last four bytes is not decoded" \
  "$(one "r'i\+3 < len\(s\)'" "'i+4 < len(s)'")"
mut "M3 a \\134 pre-pass before the loop" \
  "(lambda a: s.replace(a, a + '$PREPASS', 1) if s.count(a) == 1 else None)('$PREPASS_AT')"
mut "M4 the mountpoint used raw" \
  "$(one "r'mnt := unescapeMountPath\(fld\[1\]\)'" "'mnt := fld[1]'")"
mut "M5 the 011 (tab) case deleted" \
  "$(one "r'\t\t\tcase \"011\":\n\t\t\t\tb\.WriteByte\(\'\\\\t\'\)\n\t\t\t\ti \+= 3\n\t\t\t\tcontinue\n'" "''")"
if ! cmp -s "$W/media_seal.go.pristine" media_seal.go; then echo "== media_seal.go was not restored"; exit 1; fi
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
