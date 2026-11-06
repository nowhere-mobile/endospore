#!/usr/bin/env bash
# test-delete-busy-seal.sh [--mutate] -- runs delete_busy_seal_test.go (NWP-20261013-24); --mutate re-runs it against
# main.go with each guard removed in turn, restoring the file on exit. Each mutant must be CONVICTED; one that fails
# to apply counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestDelete(Answers|Ignores)|TestPeriodicLoopDefers|TestAnySealRunning|TestSyncLoopUsesTheDelete' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
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
mut "M1 beginDelete ignores a running seal" 'if anySealRunningLocked\(now\) \{\n\t\treturn false' 'if false {\n\t\treturn false'
mut "M2 the DELETE arm skips beginDelete" 'if !beginDelete\(time\.Now\(\)\) \{' 'if false {'
mut "M3 the expiry clause removed" 'return sealInFlight \|\| \(sealRunKind != "" && \(sealRunAt\.IsZero\(\) \|\| now\.Sub\(sealRunAt\) <= sealRunExpiry\)\)' 'return sealInFlight || sealRunKind != ""'
mut "M4 the sealInFlight clause removed" 'return sealInFlight \|\| \(sealRunKind' 'return (sealRunKind'
mut "M5 syncLoop ignores deleteInFlight" 'if reason == "" && deleteInFlight \{\n\t\treturn "delete-in-flight"' 'if false {\n\t\treturn "delete-in-flight"'
mut "M6 the announce ignores deleteInFlight" 'if deleteInFlight \{\n\t\tpendingReapMu\.Unlock\(\)\n\t\treturn false' 'if false {\n\t\tpendingReapMu.Unlock()\n\t\treturn false'
mut "M7 the flag is never set" 'deleteInFlight = true\n\treturn true' 'return true'
mut "M8 syncLoop drops the delete defer" 'reason = deleteDeferLocked\(reason\)' '_ = reason'
mut "M9 syncLoop announces without the delete check" 'if !announcePeriodicSeal\(\) \{' 'setSealRun("periodic")\n\t\tif false {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
