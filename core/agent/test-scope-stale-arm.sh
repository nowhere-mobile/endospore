#!/usr/bin/env bash
# test-scope-stale-arm.sh [--mutate] -- NWP-20261111-15: the untie and the add-device arm each scope head's stale check
# at the value they READ (scope_tie.go untieScopeHeads, addScopeSESlots), as the tie does, so a #de head published while
# the edit computes refuses it instead of being overwritten. --mutate applies each mutant to a pristine copy of
# scope_tie.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or does not compile, is a
# failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp scope_tie.go "$W/scope_tie.orig" || exit 2
trap 'cp "$W/scope_tie.orig" scope_tie.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

U1=TestScopeStaleUntieRefusesAPublishAfterItsRead
U2=TestScopeStaleAddDeviceRefusesAPublishAfterItsRead
RUN="TestScopeStale|TestUntieScopesReopensThemByPassphraseWithoutReupload|TestAddedPhoneOpensTheTiedScopes|TestEveryGoroutineGoesThroughGoSafe"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <func> <old> <new> <run>: replace the first <old> AFTER `func <func>(` in a pristine scope_tie.go --
# the two functions share most of their lines, so a file-wide first match could land in the wrong one -- and require
# a real --- FAIL from <run>.
mutate() {
  local lbl="$1" fn="$2" old="$3" new="$4" run="$5" res
  cp "$W/scope_tie.orig" scope_tie.go
  if ! FN="$fn" OLD="$old" NEW="$new" python3 -c "
import os
s = open('scope_tie.go').read()
i = s.find('func ' + os.environ['FN'] + '(')
if i < 0: raise SystemExit('function not found')
j = s.find(os.environ['OLD'], i)
k = s.find('\nfunc ', i + 1)
if j < 0 or (k >= 0 and j > k): raise SystemExit('mutant did not apply')
s = s[:j] + os.environ['NEW'] + s[j + len(os.environ['OLD']):]
open('scope_tie.go', 'w').write(s)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "$run" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "M1 the untie arms with a fresh read again" untieScopeHeads \
  'capExpect("untie", writeRef, writeOld)' 'capExpect("untie", writeRef, getRef(base, writeRef))' "$U1"
mutate "M2 the add-device arms with a fresh read again" addScopeSESlots \
  'capExpect("add-device", writeRef, writeOld)' 'capExpect("add-device", writeRef, getRef(base, writeRef))' "$U2"
mutate "M3 the untie re-reads writeOld after the blob fetch" untieScopeHeads \
  'ov, isV := parseVault(getHeadBlob(base, head))' $'ov, isV := parseVault(getHeadBlob(base, head))\n\t\t\twriteOld = getRef(base, writeRef)' "$U1"
mutate "M4 the untie's arm removed" untieScopeHeads \
  'capExpect("untie", writeRef, writeOld)' '_ = writeOld' "$U1"
cp "$W/scope_tie.orig" scope_tie.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
