#!/usr/bin/env bash
# test-seal-status-timeout.sh [--mutate] -- runs seal_status_timeout_test.go (NWP-20261113-18): a logoff seal that
# stopped making progress (ERR-TIMEOUT from runWorkerHeld's stall backstop, ERR-STALLED from the logoff stall
# watchdog) answers SEAL-STATUS "FAILED TIMEOUT", matched on the exact verb, and every other verdict is unchanged.
# The sealFailSuffix and legacy-shape pins run beside it. --mutate re-runs them against main.go with the arm broken in
# turn, restoring main.go on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
MN=main.go
trap 'if [ -f "$W/$MN.orig" ]; then cp -f "$W/$MN.orig" "$MN"; fi; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestComposeSealStatus|TestSealFailSuffix|TestSealStatusTimeout|TestSealStatusLegacyShapesUnchanged|TestSealStatusNoCreditReason' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MN" "$W/$MN.orig"
fails=0
mut() { # mut <label> <mutant id understood by the python below>
  local label=$1 res
  python3 - "$MN" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$MN.orig" "$MN"; return; }
import sys
p, k = sys.argv[1:3]
s = open(p).read()
H = 'if v := sealVerb(why); v == "ERR-TIMEOUT" || v == "ERR-STALLED" {'
G = '\t\t' + H + '\n\t\t\treturn []string{"FAILED TIMEOUT"}\n\t\t}\n'
if s.count(G) != 1: sys.exit(1)
if k == 'T1': n = s.replace(G, '')
elif k == 'T2': n = s.replace(H, 'if v := sealVerb(why); v == "ERR-TIMEOUT" {')
elif k == 'T3': n = s.replace(H, 'if v := sealVerb(why); strings.HasPrefix(v, "ERR-TIMEOUT") || v == "ERR-STALLED" {')
elif k == 'T4': n = s.replace(G, G.replace('"FAILED TIMEOUT"', '"FAILED"'))
else: sys.exit(1)
if n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -qE 'build failed|\[setup failed\]' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$MN.orig" "$MN"
}
mut "T1 the TIMEOUT arm removed" T1
mut "T2 ERR-STALLED dropped from the arm" T2
mut "T3 the arm matches every verb that starts ERR-TIMEOUT" T3
mut "T4 the arm answers bare FAILED" T4
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
