#!/usr/bin/env bash
# test-armpin-verdict.sh [--mutate] -- runs the ARM-PIN verdict cases (armpin_verdict_test.go; NWP-20261031-05);
# --mutate re-runs them against main.go with the handler broken in turn, restoring the file on exit. Each mutant must
# be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=main.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestArmPin' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$F.orig" "$F"
}
VERD='\t\t\t\tverdict = "PINNOTARMED"\n\t\t\t\tif strings.TrimSpace(string(b)) == "armed" {\n\t\t\t\t\tverdict = "PINSET"\n\t\t\t\t}\n'
KICK='\t\t\tgoSafe("armcred", func() { armPinKick(dest, nm, cred, uid, ps) })'
mut "P1 PINSET on the marker's existence (the old code)" \
  "s.replace('$VERD', '\t\t\t\tverdict = \"PINSET\"; _ = b\n', 1) if s.count('$VERD') == 1 else None"
mut "P2 PINNOTARMED answered as PINSET" \
  "s.replace('verdict = \"PINNOTARMED\"\n', 'verdict = \"PINSET\"\n', 1) if s.count('verdict = \"PINNOTARMED\"\n') == 1 else None"
mut "P3 the kick dropped on the PINNOTARMED arm" \
  "s.replace('$KICK', '\t\t\tif verdict != \"PINNOTARMED\" {\n\t\t\t\tgoSafe(\"armcred\", func() { armPinKick(dest, nm, cred, uid, ps) })\n\t\t\t}', 1) if s.count('$KICK') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
