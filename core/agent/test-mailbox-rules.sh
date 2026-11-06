#!/usr/bin/env bash
# test-mailbox-rules.sh [--mutate] -- runs mailbox_rules_test.go (NWP-20261021-10): a delete removes the session's
# mailboxes only when a stored profile was deleted, and a logoff that re-arms keeps them. --mutate re-runs it against
# main.go with each rule broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a test
# failure; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
MAIN=main.go
RUN=(go test -count=1 -run 'TestMailboxRules_' .)
W=$(mktemp -d)
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | tail -5
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/main.go.orig"
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local res
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
REARM='(\t\t\trearmRoamSession\(dest, name, pass, uid, seSecret, "%s"\)[^\n]*\n)'
mut "M1 the delete's removeMailboxes dropped" '(if uid != "" && purged \{\n)\t\t\tremoveMailboxes\(uid\)[^\n]*\n' '\1'
mut "M2 the noop arm purges" '(\tdefault: // "noop": no stored profile backs this session[^\n]*\n)' '\1\t\tpurged = true\n'
mut "M3 purged = false after the switch" '(\n)(\t// NWP-20260927-09: under telMu, so an arrival appends)' '\1\tpurged = false\n\2'
mut "M4 an unconditional removal before the switch" '(\tswitch verdict \{\n)' '\tremoveMailboxes(uid)\n\1'
mut "M5 a removal in the failed-seal arm" "${REARM/\%s/logout seal failed, re-arm}" '\1\t\t\tremoveMailboxes(uid)\n'
mut "M6 a removal in the media-sweep arm" "${REARM/\%s/logout media sweep did not verify, re-arm}" '\1\t\t\tremoveMailboxes(uid)\n'
mut "M7 a removal in the stall arm" "${REARM/\%s/logout seal stalled, re-arm}" '\1\t\t\tremoveMailboxes(uid)\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
