#!/usr/bin/env bash
# test-backup-rekey-wait.sh [--mutate] -- a Back up now tapped during a background re-key batch says what it waits
# for (NWP-20261206-13): the batch announces itself while it holds the worker slot (rekeyHoldsSlot), the reply stays
# OK with a second line "WAIT rekey-batch", and login.log says the save waits for the batch. Plain: the new tests.
# --mutate applies each mutant to scope_rekey_job.go or main.go in place (pristine copies of both live in one temp
# root, restored after every mutant and on exit) and runs the new tests; each must be CONVICTED by the named
# `--- FAIL`. A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
restore() {
  [ -f "$W/scope_rekey_job.go" ] && cp -f "$W/scope_rekey_job.go" scope_rekey_job.go
  [ -f "$W/main.go" ] && cp -f "$W/main.go" main.go
  return 0
}
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

TESTS='TestRekeyBatchAnnounces|TestBackupDuringARekeyBatch|TestBackupWithNoRekeyBatch|TestAUserOpBehindTheBatch|TestBackupWaitLine'
out=$(go test -count=1 -timeout 300s -run "$TESTS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp scope_rekey_job.go "$W/scope_rekey_job.go"
cp main.go "$W/main.go"
fails=0
T1=TestRekeyBatchAnnouncesItselfWhileItHoldsTheSlot
T2=TestBackupDuringARekeyBatchSaysWhatItWaitsFor
T3=TestBackupWithNoRekeyBatchRepliesExactlyOK
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want
  shift 4
  python3 - "$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -timeout 120s -run "$TESTS" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "W1 the batch never sets the flag" scope_rekey_job.go $'\tsetRekeyHoldsSlot(true)\n' $'\tsetRekeyHoldsSlot(false)\n' $T1
mut "W2 the batch never clears the flag" scope_rekey_job.go $'\tdefer setRekeyHoldsSlot(false) // runs before the slot\'s release: defers run last-first\n' '' $T1
mut "W3 the OK drops the wait line" main.go 'fmt.Fprint(conn, "OK\n"+backupWaitLine(waitBatch))' 'fmt.Fprint(conn, "OK\n")' $T2
mut "W4 the wait line always sent" main.go '"OK\n"+backupWaitLine(waitBatch)' '"OK\n"+backupWaitLine(true)' $T3
mut "W5 the reason put on the first line" main.go '"OK\n"+backupWaitLine(waitBatch)' '"OK "+backupWaitLine(waitBatch)' $T2
mut "W6 a batch made a refusal" main.go 'busy := why != ""' 'busy := why != "" || rekeyHoldsSlot' $T2
mut "W7 the waits log line dropped" main.go $'\t\tfmt.Fprint(os.Stderr, "[logind] manual backup waits for the re-key batch already running (NWP-20261206-13)\\n")\n' '' $T2
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
