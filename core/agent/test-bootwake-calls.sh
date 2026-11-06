#!/usr/bin/env bash
# test-bootwake-calls.sh [--mutate] -- runs boot_wake_test.go (NWP-20261114-05): the daemon's calls of roamd's bootwake
# op after GRANT-PERMS' seed-home and after each later RESTORE-ODDATA that restored a package. --mutate re-runs it with
# each call or gate broken in turn, restoring the files on exit. Each mutant must be CONVICTED by a `--- FAIL`; one
# that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(boot_wake.go main.go app_code.go)
trap 'for f in "${FILES[@]}"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestGrantTail_|TestBootWakeGate_|TestRestoreOdData' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <python-regex pattern> <repl>
  local label="$1" file="$2" res rc
  if ! python3 - "$file" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$file.orig" "$file"; return
  fi
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/$file.orig" "$file"
}
SEED='(\tverdict := strings\.TrimSpace\(seedHomeOp\(dest, uid\)\)\n\tfmt\.Fprintf\(os\.Stderr, "\[logind\] seed-home user[^\n]*\n)'
BOOT='(\tr := strings\.TrimSpace\(bootWakeOp\(dest, uid, ""\)\)\n\tfmt\.Fprintf\(os\.Stderr, "\[logind\] bootwake user[^\n]*\n)'
mut "B1 bootwake before seed-home" boot_wake.go "$SEED$BOOT" '\2\1'
mut "B2 no bootwake in grantTail" boot_wake.go 'bootWakeOp\(dest, uid, ""\)' '"BOOTWAKE 0 0"'
mut "B3 the gate never cleared at roam-in" main.go '\tbootWakeGate\.clear\(\)[^\n]*\n' ''
mut "B4 the restore tail ignores the gate" boot_wake.go '&& bootWakeGate\.armed\(uid\)' '&& true'
mut "B5 the restore tail fires on OK NOSRC" boot_wake.go 'reply == "OK "\+pkg' 'strings.HasPrefix(reply, "OK ")'
mut "B6 the gate never armed at grant" main.go '\tbootWakeGate\.arm\(uid\)\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
