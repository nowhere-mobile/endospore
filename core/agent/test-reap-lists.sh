#!/usr/bin/env bash
# test-reap-lists.sh [--mutate] -- runs the reap's file-name-list cases (reap_lists_test.go; NWP-20261129-19, h59 #11):
# CLEAN-STORAGE with no session live or parked removes a departed session's plaintext lists from the state tmpfs.
# --mutate re-runs them against a COPY of the package with each rule broken in turn; the tree is never touched. Each
# mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestReapLists' -v .)

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
mut "M1 the call removed" main.go \
  "$(one "r'\t\t\treapSessionLists\(dest\)[^\n]*\n'" "''")"
mut "M2 the marker check removed" reap_lists.go \
  "$(one "r'\tif _, _, _, state := readRoamSessionState\(dest\); state != roamSessionAbsent \{\n[^\n]*\n\t\}\n'" "''")"
mut "M3 the .coldlock check removed" reap_lists.go \
  "$(one "r'\tif _, err := os\.Lstat\(filepath\.Join\(dest, \"\.coldlock\"\)\); [^\n]*\n[^\n]*\n\t\}\n'" "''")"
mut "M4 the prefix match as strings.Contains" reap_lists.go \
  "(lambda r: r[0] if r[1] == 2 else None)(re.subn(r'strings\.HasPrefix\(name,', 'strings.Contains(name,', s))"
mut "M5 directories removed too" reap_lists.go \
  "$(one "r'if !fi\.Mode\(\)\.IsRegular\(\) \{'" "'if !fi.Mode().IsRegular() && !fi.IsDir() {'")"
mut "M6 resetSealDeltaCaches dropped" reap_lists.go \
  "$(one "r'\tresetSealDeltaCaches\(\)[^\n]*\n'" "''")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
