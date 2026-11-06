#!/usr/bin/env bash
# test-selinux-level.sh [--mutate] -- runs selinux_level_test.go (NWP-20261014-48); --mutate re-runs it against
# main.go with each check in inheritedContext broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED; one that fails to apply counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'TestInheritedContext' .)

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
mut "M1 parent-category check dropped" 'if pctx == "" \|\| !strings\.Contains\(pctx, ":c"\) \{' 'if pctx == "" {'
mut "M2 child-category check dropped" 'if cctx == pctx \|\| strings\.Contains\(cctx, ":c"\) \{' 'if cctx == pctx {'
mut "M3 identical check inverted" 'if cctx == pctx \|\| strings\.Contains\(cctx, ":c"\) \{' 'if cctx != pctx || strings.Contains(cctx, ":c") {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
