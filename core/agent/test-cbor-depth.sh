#!/usr/bin/env bash
# test-cbor-depth.sh [--mutate] -- runs the CBOR decoder tests (NWP-20261120-16): cborDec refuses an array or map nested
# past cborMaxDepth (16) with errCBOR, 1<<20 bytes of 0x81 are refused without deep recursion, and the CTAP fixtures still
# decode. --mutate re-runs them against a COPY of the package with the depth rule broken in turn; the tree is never
# touched. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestCBOR|TestCtap|TestParseAuthData' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res mrc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - "$file" "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
# within <block-regex> <n>: replace every `cborDecDepth(rest, depth+1)` inside the one match of the block with
# `cborDecDepth(rest, depth)`, and apply only when exactly n were replaced there.
within() { echo "(lambda b: None if b is None or b.group(0).count('cborDecDepth(rest, depth+1)') != $2 else s[:b.start()] + b.group(0).replace('cborDecDepth(rest, depth+1)', 'cborDecDepth(rest, depth)') + s[b.end():])(re.search($1, s, re.S))"; }
mut "M1 the depth check removed" ctap_cbor.go \
  "$(one "r'\tif \(major == 4 \|\| major == 5\) && depth >= cborMaxDepth \{\n\t\treturn nil, nil, errCBOR\n\t\}\n'" "''")"
mut "M2 > for >= (17 levels accepted)" ctap_cbor.go \
  "$(one "r'depth >= cborMaxDepth'" "'depth > cborMaxDepth'")"
mut "M3 the depth not incremented for maps" ctap_cbor.go \
  "$(within "r'case 5: // map.*?case 7:'" 2)"
mut "M4 the depth not incremented for arrays" ctap_cbor.go \
  "$(within "r'case 4: // array.*?case 5:'" 1)"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
