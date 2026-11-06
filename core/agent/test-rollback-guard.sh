#!/usr/bin/env bash
# test-rollback-guard.sh [--mutate] -- runs rollback_guard_test.go (NWP-20261013-25); --mutate re-runs it against
# main.go / ProfileActivity.java / SnapshotCopy.java with each guard removed in turn, restoring the files on exit.
# Each mutant must be CONVICTED; one that fails to apply counts as a failure. M4 mutates SnapshotCopy.java, which
# renders the chooser's ROLLBACK reply since NWP-20261116-22.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go; PA=../chooser/src/com/nowhere/chooser/ProfileActivity.java; SC=../chooser/src/com/nowhere/chooser/SnapshotCopy.java
RUN=(go test -count=1 -run 'TestRollback_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"; cp "$PA" "$PA.orig"; cp "$SC" "$SC.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"; mv -f "$PA.orig" "$PA"; mv -f "$SC.orig" "$SC"' EXIT
fails=0
mut() { # mut <label> <file> <python-regex-replace: pattern> <repl>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  if "${RUN[@]}" >/dev/null 2>&1; then echo "  SURVIVED  $1"; fails=$((fails+1)); else echo "  convicted $1"; fi
  cp "$MAIN.orig" "$MAIN"; cp "$PA.orig" "$PA"; cp "$SC.orig" "$SC"
}
mut "M1 the stash Remove dropped" "$MAIN" 'if err := os\.Remove\(filepath\.Join\(dest, ksLogoffCredsFile\)\); err != nil && !errors\.Is\(err, fs\.ErrNotExist\) \{\n\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] rollback' 'if false {\n\t\tfmt.Fprintf(os.Stderr, "[logind] rollback'
mut "M2 the sealAnnounced guard dropped" "$MAIN" 'if sealAnnounced\(\) \{\n\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] rollback' 'if false {\n\t\tfmt.Fprintf(os.Stderr, "[logind] rollback'
mut "M3 the endUnsavedBlocked guard dropped" "$MAIN" 'if why := endUnsavedBlocked\(uid\); why != "" \{\n\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] rollback' 'if why := ""; why != "" {\n\t\tfmt.Fprintf(os.Stderr, "[logind] rollback'
mut "M4 the chooser BUSY arm dropped" "$SC" '(static String rollbackReply\([^}]*?)\n[ \t]*if \(first\.equals\("BUSY"\)\)[^\n]*' '\1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
