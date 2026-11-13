#!/usr/bin/env bash
# test-backup-join.sh [--mutate] -- a Back up now tap during a running save joins it, and a stamped tap during a save
# from before the reconnect queues exactly one more (NWP-20261201-07). Plain: the join tests. --mutate applies each
# mutant to backup_join.go in place (a pristine copy lives in one temp root, restored after every mutant and on exit)
# and runs the new tests; each must be CONVICTED by the named `--- FAIL`. A mutant that fails to apply or to compile
# counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
restore() { [ -f "$W/backup_join.go" ] && cp -f "$W/backup_join.go" backup_join.go; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

NEW='TestParseBackupAfter|TestReadBackupAfter|TestQueueFollowUp|TestQueuedSave|TestStartQueuedBackup|TestBackupJoin'
out=$(go test -count=1 -timeout 300s -run "$NEW|TestBackupBusyReason|TestHandleBackupLogsItsRefusal" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp backup_join.go "$W/backup_join.go"
fails=0
# mut <label> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" old="$2" new="$3" res want
  shift 3
  python3 - backup_join.go "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -timeout 120s -run "$NEW" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "a the predates check dropped" $'return runAt.IsZero() || runAt.Unix() < after' $'return true' TestQueueFollowUp TestBackupJoinNewerRunQueuesNothing
mut "b the armed check dropped" $'strings.HasPrefix(kind, "logoff") || armed {' $'strings.HasPrefix(kind, "logoff") {' TestBackupJoinSixTapsOneFollowUp
mut "c the logoff DROP removed" $'\tcase strings.HasPrefix(kind, "logoff"):\n\t\treturn queuedDropSignOut\n' '' TestQueuedSaveStep TestQueuedSaveDropsOnSignOut
mut "d the landed DROP removed" $'\tcase landed >= after:\n\t\treturn queuedDropLanded\n' '' TestQueuedSaveStep
mut "e the read deadline removed" $'\tconn.SetReadDeadline(time.Now().Add(backupAfterWait))\n' '' TestReadBackupAfter
mut "f digits accepted without the AFTER prefix" $'digits, ok := strings.CutPrefix(strings.TrimSpace(line), "AFTER ")' $'digits, ok := strings.TrimPrefix(strings.TrimSpace(line), "AFTER "), true' TestParseBackupAfter
mut "g a BUSY start ends the waiter" $'case strings.HasPrefix(reply, "BUSY"):\n\t\t\t\tcontinue' $'case strings.HasPrefix(reply, "BUSY"):\n\t\t\t\treturn' TestQueuedSaveWaitsOnBusyStart
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
