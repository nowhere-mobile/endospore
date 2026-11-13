#!/usr/bin/env bash
# test-seal-delta-run.sh [--mutate] -- runs the SEAL-DELTA run-field cases (seal_delta_run_test.go and
# TestSealDeltaReplyShape; NWP-20261202-36): runStart is the live run's own announce and runProg its current progress
# frame, both only while a run is announced. --mutate re-runs them against seal_delta.go with the fields broken in
# turn, restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure. Convicting tests:
#   D1 the RunStart assignment removed            -- TestSealDeltaRunStartIsTheLiveAnnounce
#   D2 RunStart read from lastSealStartedAt        -- TestSealDeltaRunStartIsTheLiveAnnounce
#   D3 the sealRunKind guard on RunStart removed   -- TestSealDeltaNoRunOmitsRunFields
#   D4 the r.Run guard on RunProg removed          -- TestSealDeltaNoRunOmitsRunFields (its sealInFlight case)
#   D5 RunProg keeps the "SEALING " prefix         -- TestSealDeltaRunProgIsTheLiveFrame
#   D6 omitempty dropped from runStart's tag       -- TestSealDeltaNoRunOmitsRunFields
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(seal_delta.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestSealDeltaRun|TestSealDeltaNoRun|TestSealDeltaReplyShape' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
# mut <label> <file> <python expression over s (the file) and body (the handler's text)>: exactly one application.
mut() {
  local label=$1 res
  python3 - "$2" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
m = re.search(r'func handleSealDelta\(.*?\n}\n', s, re.S)
body = m.group(0) if m else ''
def inh(old, new):
    if body.count(old) != 1: return None
    return s.replace(body, body.replace(old, new, 1), 1)
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  restore
}
mut "D1 the RunStart assignment removed" seal_delta.go \
  "inh('\t\tr.RunStart = sealRunAt.Unix()', '\t\t_ = 0 //')"
mut "D2 RunStart read from lastSealStartedAt" seal_delta.go \
  "inh('r.RunStart = sealRunAt.Unix()', 'r.RunStart = lastSealStartedAt.Load()')"
mut "D3 the sealRunKind guard on RunStart removed" seal_delta.go \
  "inh('if sealRunKind != \"\" && !sealRunAt.IsZero() {', 'if !sealRunAt.IsZero() {')"
mut "D4 the r.Run guard on RunProg removed" seal_delta.go \
  "inh('if r.Run != \"\" {', 'if true {')"
mut "D5 RunProg keeps the SEALING prefix" seal_delta.go \
  "inh('strings.TrimPrefix(l[0], \"SEALING \")', 'l[0]')"
mut "D6 omitempty dropped from runStart's tag" seal_delta.go \
  "s.replace('\`json:\"runStart,omitempty\"\`', '\`json:\"runStart\"\`', 1) if s.count('\`json:\"runStart,omitempty\"\`') == 1 else None"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
