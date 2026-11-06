#!/usr/bin/env bash
# test-create-staged-reply.sh [--mutate] -- runs create_staged_reply_test.go (NWP-20261101-10); --mutate re-runs it
# against main.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL` (one that does not apply, or does not compile, is a failure).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'if [ -f "$W/main.go.orig" ]; then mv -f "$W/main.go.orig" main.go; fi; rm -rf "$W"' EXIT
MAIN=main.go
RUN=(go test -count=1 -run 'TestCreateStagedReply' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/main.go.orig"
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local mout
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$mout"; then echo "  convicted $1"
  elif [ -n "$(grep -E '\[build failed\]|^# ' <<<"$mout")" ]; then echo "  NOBUILD   $1 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "S1 the agent never appends STAGED" 'return verb \+ " STAGED\\n"' 'return verb + "\\n"'
mut "S2 the agent appends STAGED with no file" 'if _, err := os\.Stat\(staged\); err == nil \{' 'if _, err := os.Stat(staged); err == nil || true {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
