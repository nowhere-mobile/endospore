#!/usr/bin/env bash
# test-fetchapp-signout.sh [--mutate] -- runs the FETCH-APP sign-out cases (fetchapp_signout_test.go; Q116,
# NWP-20261109-14): a sign-out raised during a body, between two APKs or before the first download ends FETCH-APP with
# ERR-CANCELLED and no stage left. --mutate re-runs them against catalog.go with each part broken in turn, restoring
# the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a
# failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=catalog.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestFetchAppSignout' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res rc
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
def once(old, new):
    return s.replace(old, new, 1) if s.count(old) == 1 else None
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/$F.orig" "$F"
}
mut "M1 the sign-out watcher is never started" \
  "once('\tgoSafe(\"fetchapp-signout\", func() {\n\t\tselect {\n\t\tcase <-so:\n\t\t\tcancel(errSignOutCancel)\n\t\tcase <-ctx.Done():\n\t\t}\n\t})\n', '')"
mut "M2 a failed download is mapped as before, the sign-out unchecked" \
  "once('\t\t\tif signedOut() { // a body the sign-out cut is never reported as a mismatch\n\t\t\t\tcancelled()\n\t\t\t\treturn\n\t\t\t}\n', '')"
mut "M3 the cancel path leaves the stage" \
  "once('(Q116)\\\\n\", pkg)\n\t\tos.RemoveAll(stage)\n', '(Q116)\\\\n\", pkg)\n')"
mut "M4 no check before a download" \
  "once('\t\tif signedOut() {\n\t\t\tcancelled()\n\t\t\treturn\n\t\t}\n\t\tif err := fetchAndVerify(', '\t\tif err := fetchAndVerify(')"
mut "M5 signedOut reads only the cancel cause, not the channel" \
  "once('\tsignedOut := func() bool {\n\t\tselect {\n\t\tcase <-so:\n\t\t\treturn true\n\t\tdefault:\n\t\t}\n', '\tsignedOut := func() bool {\n')"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
