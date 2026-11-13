#!/usr/bin/env bash
# test-seal-stop-daemon.sh [--mutate] -- runs the TestSealStopDaemon tests in seal_stop_daemon_test.go
# (NWP-20261117-04, h47 #1 part 2): LOGOUT raises $NOWHERE_STATE/.sealstop only when the announce it replaces is a
# periodic seal; runWorkerHeld drops it under the slot immediately before an out op's request is written, after every
# guard, so a skipped out op and one answered busy behind an abandoned op leave it; recordSeal records no verdict for a
# SKIP-STOPPED periodic; end to end, a sign-out during a running periodic stops it and its own out request is written
# once, after the request is gone. h49 #13 (NWP-20261119-03) widens the run to seal_stop_manual_test.go's
# TestManualStop and TestSealKind: LOGOUT raises the request over a "manual" announce too and runs its out op as
# "logoff-pinned"; a stopped Back up now records nothing; the manual's end and its progress relay leave a sign-out's
# announce alone (T2/T3 run handleBackup's goroutine itself against the fake init); sealKind() pins "logoff-pinned".
# NWP-20261126-11 adds: a Back up now still queued for the slot when a sign-out takes its announce answers SKIP-STOPPED
# under the slot and leaves the request (runWorkerHeld's manualStoppedAtSlot check, seal_stop.go); the sign-out's own
# out op, a manual under its own announce and a manual after the sign-out ended still run; end to end, a Back up now
# queued behind a held slot and then a sign-out write exactly one out request, "logoff-pinned".
# h59 #1 (NWP-20261129-23) widens the run to seal_stop_promote_test.go's TestPromoteStop: LOGOUT raises the request over a
# "promote" announce too and runs its out op as plain "logoff"; a promote seal queued for the slot when a sign-out takes
# its announce answers SKIP-STOPPED under the slot and leaves the request (promoteStoppedAtSlot, seal_stop.go); a stopped
# promote records nothing; end to end, "Save to your store" and then Log off write one sign-out seal.
# --mutate re-runs them against main.go and seal_stop.go with each rule broken in turn, restoring it on exit (the pristine copy lives in
# one scratch root, never beside the source). Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to
# apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
trap 'for f in main.go seal_stop.go; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestSealStopDaemon|TestManualStop|TestSealKind|TestPromoteStop' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp seal_stop.go "$W/seal_stop.go.orig"
fails=0
mut() { # mut <label> <file> <regex pattern> <repl, with \1-style group references> [count, default 1]
  local label="$1" f="$2" res
  python3 - "$f" "$3" "$4" "${5:-1}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep,want=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,flags=re.S)
if c!=want: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $label"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp "$W/$f.orig" "$f"
}
# The drop block in runWorkerHeld, as one pattern: D3 deletes it, D5 moves it above the abandoned-lane check.
DROP='\tif op == "out" \{\n\t\t// h47 #1 \(NWP-20261117-04\): drop a sign-out[^\n]*\n(?:\t\t//[^\n]*\n)*\t\tdropSealStop\(dest\)\n\t\}\n'
# D1/D2 (re-pointed by NWP-20261119-03 at the raise line): each replacement keeps every variable in the condition, and
# the log label reads stopPeriodic as well, so neither mutant leaves a local unused (Go would refuse to compile it).
mut "D1 handleLogout raises nothing" main.go \
  'if stopPeriodic \|\| stopManual \|\| stopPromote \{' 'if false && (stopPeriodic || stopManual || stopPromote) {'
mut "D2 handleLogout raises for the empty announce too" main.go \
  'if stopPeriodic \|\| stopManual \|\| stopPromote \{' 'if true || stopPeriodic || stopManual || stopPromote {'
mut "D3 runWorkerHeld does not drop the request before roam.req" main.go \
  "$DROP" ''
mut "D4 recordSeal records SKIP-STOPPED as a verdict" main.go \
  'v == "SKIP-SUPERSEDED" \|\| v == "SKIP-STOPPED"' 'v == "SKIP-SUPERSEDED"'
mut "D5 the drop placed before the abandoned-lane check" main.go \
  "(\tif abandoned := laneAbandonedOp\(lane\); abandoned != \"\" \{\n.*?)$DROP" '\tif op == "out" {\n\t\tdropSealStop(dest)\n\t}\n\1'
# h49 #13 (NWP-20261119-03).
mut "D6 the manual raise removed" main.go \
  'stopManual := sealRunKind == "manual"' 'stopManual := false'
mut "D7 the manual's end clears unconditionally (pre-fix)" main.go \
  '(func endManualSealRun\(\) \{\n\tpendingReapMu\.Lock\(\)\n\tdefer pendingReapMu\.Unlock\(\)\n)\tif sealRunKind == "manual" \{\n\t\tsealInFlight = false\n\t\tsealRunKind = ""\n\t\}\n' \
  '\1\tsealInFlight = false\n\tsealRunKind = ""\n'
mut "D8 a verdict recorded on SKIP-STOPPED" main.go \
  '(func manualSaveDone\([^)]*\) \{\n)\tif manualStoppedBySignOut\(out\) \{\n\t\treturn\n\t\}\n' '\1'
mut "D9 the sign-out does not pin" main.go \
  'outKind = "logoff-pinned"' 'outKind = "logoff"'
mut "D10 sealKind ignores logoff-pinned" main.go \
  'case "manual", "logoff-pinned":' 'case "manual":'
mut "D11 the manual's relay writes the bar under a sign-out" main.go \
  '(func relayManualProg\([^)]*\) \{\n\taccumSaveScope\(comp, p\)\n\tpendingReapMu\.Lock\(\)\n)\tif sealRunKind == "manual" \{\n\t\tsealProg = p\n\t\}\n' \
  '\1\tsealProg = p\n'
# D12/D13 restore handleBackup's own pre-fix code and leave the helpers intact, so a test that calls the helpers
# directly cannot convict them: only a test that runs the manual goroutine can.
mut "D12 handleBackup's defer restored to the unconditional clear (pre-fix)" main.go \
  '(logSafeErrText\(r\)\)\n\t\t\t\}\n)\t\t\tendManualSealRun\(\)\n' \
  '\1\t\t\tpendingReapMu.Lock()\n\t\t\tsealInFlight = false\n\t\t\tif sealRunKind == "manual" {\n\t\t\t\tsealRunKind = ""\n\t\t\t}\n\t\t\tpendingReapMu.Unlock()\n'
mut "D13 handleBackup's relay restored to the unconditional write (pre-fix)" main.go \
  '\t\t\trelayManualProg\(comp, p\)\n' \
  '\t\t\taccumSaveScope(comp, p)\n\t\t\tpendingReapMu.Lock()\n\t\t\tsealProg = p\n\t\t\tpendingReapMu.Unlock()\n'
# NWP-20261126-11: the queued-manual check in runWorkerHeld, as one pattern (its comment, the if, the log, the return).
QCHECK='\t// h49 #13 \(NWP-20261126-11\)[^\n]*\n(?:\t//[^\n]*\n)*\tif op == "out" && manualStoppedAtSlot\(intent\) \{\n\t\tfmt\.Fprintf\([^\n]*\n\t\treturn "SKIP-STOPPED"\n\t\}\n'
mut "D14 runWorkerHeld runs a queued manual under a sign-out (check deleted)" main.go \
  "$QCHECK" ''
mut "D15 the helper skips every announce but manual" seal_stop.go \
  'return sealRunKind == "logoff"' 'return sealRunKind != "manual"'
mut "D16 the helper's intent guard dropped (the sign-out would skip its own seal)" seal_stop.go \
  '\tif intent != "manual" \{\n\t\treturn false\n\t\}\n' ''
mut "D17 the check moved after the drop" main.go \
  "($QCHECK)(.*?)($DROP)" '\2\3\1'
# h59 #1 (NWP-20261129-23): the queued-promote check in runWorkerHeld, as one pattern, in QCHECK's form.
PCHECK='\t// h59 #1 \(NWP-20261129-23\)[^\n]*\n(?:\t//[^\n]*\n)*\tif op == "out" && promoteStoppedAtSlot\(intent\) \{\n\t\tfmt\.Fprintf\([^\n]*\n\t\treturn "SKIP-STOPPED"\n\t\}\n'
mut "D18 the promote raise removed" main.go \
  'stopPromote := sealRunKind == "promote"' 'stopPromote := false'
mut "D19 the promote at-slot check removed" main.go \
  "$PCHECK" ''
mut "D20 the promote passes intent \"\" again" main.go \
  'readRoamSessionSE\(dest\), "", "", "promote", nil\)' 'readRoamSessionSE(dest), "", "", "", nil)'
mut "D21 a replaced promote pins" main.go \
  'if stopManual \{\n\t\t\toutKind' 'if stopManual || stopPromote {\n\t\t\toutKind'
mut "D22 the promote helper's intent guard dropped (the sign-out would skip its own seal)" seal_stop.go \
  '\tif intent != "promote" \{\n\t\treturn false\n\t\}\n' ''
mut "D23 the promote check moved after the drop" main.go \
  "($PCHECK)(.*?)($DROP)" '\2\3\1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
