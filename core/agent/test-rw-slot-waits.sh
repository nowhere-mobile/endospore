#!/usr/bin/env bash
# test-rw-slot-waits.sh [--mutate] -- runs rw_slot_waits_test.go (NWP-20261208-11): the RW-lane slot waits of 5 s or
# more by waiting op and the op holding the slot when it queued, and the holds of 5 s or more by op, reach every issue
# report, at both scopes, as op codes and integers only. --mutate re-runs the cases against a COPY of the package with
# each part broken in turn; the checked-out files are never edited. Each mutant must be CONVICTED by its named test's
# `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure. A comment edit (the control) must pass.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 180s -run '^TestRwSlot' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/agent"
mkdir "$P" && cp -a . "$P" || exit 2
FILES=(rw_slot_waits.go main.go report_issue.go)
fails=0
apply() { # apply <file> <python-regex> <replacement>: exactly one substitution, or exit 1
  local f
  for f in "${FILES[@]}"; do cp -f "$f" "$P/$f" || return 1; done
  python3 - "$P/$1" "$2" "$3" <<'PY'
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
if len(re.findall(pat, s, flags=re.S)) != 1: sys.exit(1)
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1, flags=re.S)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
}
mut() { # mut <label> <expected failing test> <file> <python-regex> <replacement>
  local label=$1 want=$2 res rc
  apply "$3" "$4" "$5" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
  if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  elif [ "$rc" -ne 0 ] && [[ "$res" == *"--- FAIL: $want "* ]]; then echo "  convicted $label ($want)"
  else echo "  SURVIVED  $label -- no --- FAIL: $want"; tail -n 15 <<<"$res"; fails=$((fails+1)); fi
}
ctl() { # ctl <label> <file> <python-regex> <replacement>: an edit that changes no behaviour must PASS
  local label=$1 res rc
  apply "$2" "$3" "$4" || { echo "  INERT     $label -- the control edit did not apply"; fails=$((fails+1)); return; }
  res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  passed    $label (control)"
  else echo "  FAILED    $label -- the control must pass"; tail -n 15 <<<"$res"; fails=$((fails+1)); fi
}

mut "X1 the floor made >" TestRwSlotWaitsFloor rw_slot_waits.go \
  'return ms >= rwSlotWaitFloor\.Milliseconds\(\)' 'return ms > rwSlotWaitFloor.Milliseconds()'
mut "X2 the holder read after the acquire" TestRwSlotQueuedBehindHolder main.go \
  '\twaitHolder, _ := rwHolderOp\.Load\(\)\.\(string\)([^\n]*\n)(.*?)(\t\trwSlotWaits\.wait\(op, waitHolder, time\.Since\(tLock\))' \
  '\tvar waitHolder string\1\2\t\twaitHolder, _ = rwHolderOp.Load().(string)\n\3'
mut "X3 opClass returns its input" TestRwSlotWaitsOpClass rw_slot_waits.go \
  '(func opClass\(s string\) string \{\n)' '\1\treturn s\n'
mut "X4 the 32-key cap removed" TestRwSlotWaitsCap rw_slot_waits.go \
  'len\(m\) >= rwSlotKeyCap' 'false'
mut "X5 the report key dropped" TestRwSlotIssueReportKey report_issue.go \
  '\tstatus\["rw_slot_waits"\] = rwSlotWaits\.value\(\)\n' ''
mut "X6 the RW-lane test removed" TestRwSlotQueuedBehindHolder main.go \
  'if lane\.svc == laneRW\.svc \{(\n\t\trwSlotWaits\.wait\(op, waitHolder, time\.Since)' 'if true {\1'
mut "X7 hold() never called" TestRwSlotQueuedBehindHolder main.go \
  '\t+rwSlotWaits\.hold\(op, h\.Milliseconds\(\)\)[^\n]*\n' ''
ctl "C0 a comment edit" rw_slot_waits.go \
  '// rwSlotKeyCap bounds each map' '// rwSlotKeyCap caps each map'
[ "$fails" -eq 0 ] && echo "== all 7 mutations convicted, control survived" || { echo "== $fails mutation(s) or control(s) failed"; exit 1; }
