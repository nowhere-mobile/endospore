#!/usr/bin/env bash
# test-head-unreadable.sh [--mutate] -- NWP-20261124-07 (#5 of the 2026-11-02 entry): an unreadable bare vault head is a
# store failure, never "not locked" and never a throwaway. Runs locked_head_unreadable_test.go and the pins beside it;
# --mutate applies each mutant to a pristine copy of main.go, locked_head.go or mediafs.go (all three restored on exit)
# and requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a pass.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp locked_head.go "$W/locked_head.go.orig" || exit 2
cp mediafs.go "$W/mediafs.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/locked_head.go.orig" locked_head.go; cp "$W/mediafs.go.orig" mediafs.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestHeadUnreadable|TestVaultHead|TestLockedHead|TestScopeRestoreRefused|TestScopeOwner|TestMediad|TestBareHeadReads|TestLateWork|TestFailedSignin'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
restore_pristine() {
  cp "$W/main.go.orig" main.go
  cp "$W/locked_head.go.orig" locked_head.go
  cp "$W/mediafs.go.orig" mediafs.go
}
# mutate <label> <file> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" body="$3" o r
  restore_pristine
  if ! python3 -c "
s = open('$f').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('$f','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); restore_pristine; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1); r=$?
  score_mutant "$lbl" "$r" "$o" || FAILS=$((FAILS+1))
  restore_pristine
}
echo "== mutations =="
mutate "m1: the unreadable arm of vaultHeadLocked answers not locked" locked_head.go "
t = s.replace('\tv, err := readHeadVault(base, head)\n\tif err != nil {\n\t\treturn false, true\n', '\tv, err := readHeadVault(base, head)\n\tif err != nil {\n\t\treturn false, false\n', 1)"
mutate "m2: handleRoamIn's unreadable arm falls through to the throwaway" main.go "
t = s.replace('\t\t\troamInHeadUnreadable(conn, dest, name)\n\t\t\treturn\n', '\t\t\thead = \"\"\n', 1)"
mutate "m3: the BLANK NET arm runs after markRoamSession" main.go "
t = s.replace('\t\t\troamInHeadUnreadable(conn, dest, name)\n', '\t\t\tmarkRoamSession(dest, name, pass, uid, seSecret)\n\t\t\troamInHeadUnreadable(conn, dest, name)\n', 1)"
mutate "m4: scopeHeadMayBeCreated treats unreadable as present and open" main.go "
t = s.replace('not creating the scope head (NWP-20261124-07)\\\\n\", logProfile(profile))\n\t\treturn false\n', 'not creating the scope head (NWP-20261124-07)\\\\n\", logProfile(profile))\n\t\treturn true\n', 1)"
mutate "m5: the scope guard reads the bare ref leniently" locked_head.go "
t = s.replace('headRefWith(base, bare, pass, memo.probeStrict)', 'headRefWith(base, bare, pass, memo.probe)', 1)"
mutate "m6: the restore verb's unreadable arm returns instead of exiting store-unreachable" main.go "
t = s.replace('(store unreachable) (NWP-20261124-07)\\\\n\", logProfile(profile))\n\t\t\tos.Exit(exitStoreUnreachable)\n', '(store unreachable) (NWP-20261124-07)\\\\n\", logProfile(profile))\n\t\t\treturn\n', 1)"
mutate "m7: the sign-in reads the bare ref leniently" locked_head.go "
t = s.replace('_, head, _ = headRefWith(base, name, pass, refProbeStrict)', '_, head, _ = headRefWith(base, name, pass, refProbe)', 1)"
mutate "m8: mediad serves on an unreadable head" mediafs.go "
t = s.replace('\tif unreadable {\n\t\tdlog(\"mediad: the store could not be read', '\tif unreadable && name == \"\" {\n\t\tdlog(\"mediad: the store could not be read', 1)"
mutate "m9: restore-app exits 1 on an unreadable head" main.go "
t = s.replace('the store could not be read -> refusing (NWP-20261124-07)\\\\n\", logProfile(scope))\n\t\t\tos.Exit(exitStoreUnreachable)', 'the store could not be read -> refusing (NWP-20261124-07)\\\\n\", logProfile(scope))\n\t\t\tos.Exit(1)', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "9 mutants convicted"
