#!/usr/bin/env bash
# test-enroll-durable.sh [--mutate] -- runs the CREATE-throttle limiter cases (the three in enroll_durable_test.go and
# the four in enroll_test.go, by one anchored -run pattern; NWP-20261118-23); --mutate re-runs them against main.go
# with saveEnroll broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=main.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run '^TestEnroll(BurstThenThrottle|Disabled|RefillOverTime|Persists|FailedSave\w*|SavePublishes\w*)$' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res rc
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/$F.orig" "$F"
}
SAVE='\t\terr = writeConfDurable(enrollStatePath(), raw)\n'
mut "E1 saveEnroll writes the bucket in place with os.WriteFile (the old code)" \
  "s.replace('$SAVE', '\t\terr = os.WriteFile(enrollStatePath(), raw, 0o600)\n', 1) if s.count('$SAVE') == 1 else None"
mut "E2 saveEnroll writes a temp file and renames it, without the sync" \
  "s.replace('$SAVE', '\t\ttmp := enrollStatePath() + \".tmp\"\n\t\tif err = os.WriteFile(tmp, raw, 0o600); err == nil {\n\t\t\terr = os.Rename(tmp, enrollStatePath())\n\t\t}\n', 1) if s.count('$SAVE') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
