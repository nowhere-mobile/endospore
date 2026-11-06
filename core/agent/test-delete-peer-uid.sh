#!/usr/bin/env bash
# test-delete-peer-uid.sh [--mutate] -- runs delete_peer_uid_test.go (NWP-20261102-09, Q034): a DELETE whose session
# marker has no uid takes the caller's Android user from the socket and reaps it; user 0 or an unknown caller keeps the
# reboot. --mutate re-runs the focused tests against a pristine copy of main.go with each rule broken in turn,
# restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply, or fails to
# compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run 'DeletePeer|DeleteUnreachable|MailboxRules' .)
W=$(mktemp -d) || exit 2
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
mkdir -p "$W/tmp" && export TMPDIR="$W/tmp" GOTMPDIR="$W/tmp"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/main.go.orig"
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local res
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$W/main.go.orig" "$MAIN"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  else
    if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- did not compile"; else echo "  SURVIVED  $1"; fi
    fails=$((fails+1))
  fi
  cp "$W/main.go.orig" "$MAIN"
}
mut "U1 the derived uid ignored" '\t\tuid = strconv\.Itoa\(peer / 100000\)\n' '\t\t_ = peer\n'
mut "U2 user 0 accepted (peer >= 0)" 'if uid == "" && peer >= 100000 \{' 'if uid == "" && peer >= 0 {'
mut "U3 the peer beats the marker uid" 'if uid == "" && peer >= 100000 \{' 'if peer >= 100000 {'
mut "U4 mailboxes not removed on the derived arm" 'if uid != "" && purged \{' 'if uid != "" && purged && peer < 100000 {'
mut "U5 the dispatcher drops the peer" '(handleDeleteFn\(conn, dest, [^\n]*), peerUID\(conn\)\)' '\1, -1)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
