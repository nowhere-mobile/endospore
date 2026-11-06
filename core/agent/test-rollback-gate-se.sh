#!/usr/bin/env bash
# test-rollback-gate-se.sh [--mutate] -- runs rollback_gate_se_test.go (NWP-20261016-20); --mutate re-runs it against
# main.go with each link of the gate's secret hand-off broken in turn, restoring the file on exit. Each mutant must
# be CONVICTED; one that fails to apply counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestRollbackGate' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <repl>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  if "${RUN[@]}" >/dev/null 2>&1; then echo "  SURVIVED  $1"; fails=$((fails+1)); else echo "  convicted $1"; fi
  cp "$MAIN.orig" "$MAIN"
}
mut "M1 the helper is handed nil again" 'rollbackHead\(base, name, pass, 0, se\)' 'rollbackHead(base, name, pass, 0, nil)'
mut "M2 the third line is read but dropped" 'strings\.TrimRight\(gp, "\\r\\n"\), strings\.TrimRight\(gs, "\\r\\n"\)\)' 'strings.TrimRight(gp, "\r\n"), "")'
mut "M3 the secret is passed as raw hex bytes" 'rollbackGateReply\("s3", name, pass, seFromHex\(se\)\)' 'rollbackGateReply("s3", name, pass, []byte(se))'
mut "M4 the dispatcher reads two lines again" 'gs, _ := r\.ReadString\(.\\n.\)\n' 'gs := ""\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
