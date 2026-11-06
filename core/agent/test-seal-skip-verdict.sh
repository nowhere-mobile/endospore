#!/usr/bin/env bash
# test-seal-skip-verdict.sh [--mutate] -- runs seal_skip_verdict_test.go (NWP-20261108-20): a periodic seal skipped as
# SKIP-SUPERSEDED ran no seal, so recordSeal leaves the backup-health verdict (and the credit / refusal stashes the
# superseding seal takes) alone, while SKIP-REAPING, ERR-WORKER-BUSY and ERR-TIMEOUT are still recorded as "fail".
# --mutate re-runs them against main.go with the guard broken in turn, restoring main.go on exit. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
MN=main.go
trap 'if [ -f "$W/$MN.orig" ]; then cp -f "$W/$MN.orig" "$MN"; fi; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestSealSkipVerdict|TestEndUnsaved_ALaterSealThatNoLongerRefusesTheScopeWithdrawsTheLicence' -v .)

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
# NWP-20261117-04: the guard also returns for SKIP-STOPPED (h47 #1); seal_stop_daemon_test.go pins that half.
G = '\tif v := sealVerb(out); v == "SKIP-SUPERSEDED" || v == "SKIP-STOPPED" {\n\t\treturn\n\t}\n'
H = 'if v := sealVerb(out); v == "SKIP-SUPERSEDED" || v == "SKIP-STOPPED" {'
T = '\treason := takeCreditReason()\n'
if s.count(G) != 1 or s.count(T) != 1: sys.exit(1)
if k == 'K1': n = s.replace(G, '')
elif k == 'K2': n = s.replace(H, 'if strings.HasPrefix(sealVerb(out), "SKIP-") {')
elif k == 'K3': n = s.replace(H, 'if v := sealVerb(out); v == "SKIP-SUPERSEDED" || v == "SKIP-STOPPED" || v == workerBusy {')
elif k == 'K4': n = s.replace(H, 'if v := sealVerb(out); v == "SKIP-SUPERSEDED" || v == "SKIP-STOPPED" || v == "ERR-TIMEOUT" {')
elif k == 'K5': n = s.replace(G, '').replace(T, T + G)
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
mut "K1 the early return removed" K1
mut "K2 it matches every SKIP- verdict" K2
mut "K3 it also matches workerBusy" K3
mut "K4 it also matches ERR-TIMEOUT" K4
mut "K5 it sits below takeCreditReason" K5
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
