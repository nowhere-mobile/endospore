#!/usr/bin/env bash
# test-oddata-census.sh [--mutate] -- runs the restore-oddata census cases (oddata_census_test.go; NWP-20261202-27,
# h53 #1): each RESTORE-ODDATA request that reaches the worker writes one login.log line with its form, its phase,
# its reply counts and its wall time, and names no package or profile. --mutate re-runs them against a COPY of the
# package with each part broken in turn; the tree is never touched. Each mutant must be CONVICTED by a real
# `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestOddataCensus' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res rc
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
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}
# subn <pattern> <replacement> <count of substitutions it must make>
subn() { echo "(lambda r: r[0] if r[1] == $3 else None)(re.subn($1, $2, s))"; }
# m1: _OneAtSignin and _ListInSession convict it (no census line; phase and start stay used so it compiles).
mut "m1 the census line removed" app_code.go \
  "$(subn "r'c\.log\(uid, \"(?:one|list)\"[^\n]*'" "'_, _ = phase, start'" 2)"
# m2: _PhaseReadOnce convicts it: op 1 arms the gate, so a phase read after the loop says session.
mut "m2 phase read after the loop" app_code.go \
  "$(subn "r'\tphase := odCensusPhase\(uid\)\n([\s\S]*?)(\tfmt\.Fprintf\(conn, \"END %d\\\\n\", ran\)\n)'" "lambda m: m.group(1) + '\tphase := odCensusPhase(uid)\n' + m.group(2)" 1)"
# m3: _ListInSession convicts it (ok=2 nosrc=0).
mut "m3 OK NOSRC counted as ok" app_code.go \
  "$(subn "r'\tcase \"OK \" \+ pkg:\n\t\tc\.ok\+\+\n\tcase \"OK NOSRC\":\n\t\tc\.nosrc\+\+\n'" "'\tcase \"OK \" + pkg, \"OK NOSRC\":\n\t\tc.ok++\n'" 1)"
# m4: _CancelStops convicts it (stopped=0).
mut "m4 STOPPED not counted" app_code.go \
  "$(subn "r'\t+c\.stopped\+\+\n'" "''" 1)"
# m5: _NoNames convicts it (the line names the planted packages).
mut "m5 the package names added to the line" app_code.go \
  "$(subn "r'c\.log\(uid, \"list\", len\(pkgs\), phase, start\)'" "'c.log(uid+\" \"+strings.Join(pkgs, \",\"), \"list\", len(pkgs), phase, start)'" 1)"
# m6: _GuardsWriteNone convicts it (the one-name NONE guard writes a line).
mut "m6 a census line on the NONE guard" app_code.go \
  "$(echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn(r'(\t\t\tfmt\.Fprint\(conn, \"NONE\\\\n\"\))', lambda m: '\t\t\tnew(odCensus).log(uid, \"one\", 1, \"signin\", time.Now())\n' + m.group(1), s, count=1))")"
# m7: _Duration convicts it (the ms no longer covers the two 30 ms ops).
mut "m7 the duration start set after the loop" app_code.go \
  "$(subn "r'\tstart := time\.Now\(\)\n([\s\S]*?)(\tfmt\.Fprintf\(conn, \"END %d\\\\n\", ran\)\n)'" "lambda m: m.group(1) + '\tstart := time.Now()\n' + m.group(2)" 1)"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
