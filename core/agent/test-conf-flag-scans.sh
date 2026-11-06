#!/usr/bin/env bash
# test-conf-flag-scans.sh [--mutate] -- runs the conf-flag source scans (NWP-20261024-06): conf_flags_scoped_test.go
# and conf_flags_wired_test.go read the daemons in core/vendor-common/bin and not the test-*.sh suites beside them,
# and a profile with two push sites is refused rather than the later one winning. --mutate re-runs them against a
# COPY of core/agent and core/vendor-common/{bin,etc} under a temp root (the tests read ../vendor-common): the scan
# helpers broken in turn (M1-M4), and the daemon regressions the scans exist to catch planted in the copied scripts
# (F1, F2). The checked-out tree is never touched. Each must be CONVICTED by a `--- FAIL`; one that fails to apply,
# or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -v -run '^(TestScopeRestrictedFlags|TestPassthroughFlagsAreOptedInByExactlyTheirOwnScope|TestDaemonScriptsExcludeSuitesAndPushSitesAreUnique|TestEveryDocumentedConfFlagIsExportedByADaemon)' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
# These tests SKIP when ../vendor-common/bin is unreadable, and a skip reads as green.
for want in '--- PASS: TestDaemonScriptsExcludeSuitesAndPushSitesAreUnique' '--- PASS: TestEveryDocumentedConfFlagIsExportedByADaemon'; do
  [[ "$out" == *"$want"* ]] || { echo "FAIL: no '$want' line"; exit 1; }
done
[[ "$out" == *'--- SKIP'* ]] && { echo "FAIL: a test skipped -- the source tree was not read"; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

SRC=conf_flags_scoped_test.go
C="$W/core"
mkdir -p "$C/vendor-common"
cp -a . "$C/agent"
cp -a ../vendor-common/bin ../vendor-common/etc "$C/vendor-common/"
fails=0
mut() { # mut <label> <file under the copied core/> <python-regex pattern> <replacement> <expected FAIL line> [planted suite line]
  local res
  cp -f "$SRC" "$C/agent/$SRC"
  cp -f ../vendor-common/bin/nowhere_login.sh ../vendor-common/bin/nowhere_roamd.sh "$C/vendor-common/bin/"
  rm -f "$C/vendor-common/bin/test-zz-shadow.sh"
  python3 - "$C/$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  [ -z "${6:-}" ] || printf '%s\n' "$6" > "$C/vendor-common/bin/test-zz-shadow.sh"
  res=$(cd "$C/agent" && "${RUN[@]}" 2>&1)
  if [[ "$res" == *"$5"* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
}
NEW='--- FAIL: TestDaemonScriptsExcludeSuitesAndPushSitesAreUnique'
mut "M1 listDaemonScripts keeps the test-*.sh suites" agent/$SRC ' \|\| strings\.HasPrefix\(name, "test-"\)' '' "$NEW"
mut "M2 scanPushSites lets the later site win" agent/$SRC '(func scanPushSites.*?if first, dup := where\[m\[1\]\]; dup) \{' '\1 && first == "" {' "$NEW"
mut "M3 scanPushHelperCalls lets the later call win" agent/$SRC '(func scanPushHelperCalls.*?if first, dup := where\[m\[1\]\]; dup) \{' '\1 && first == "" {' "$NEW"
mut "M4 listDaemonScripts drops the nowhere_roamd.sh control" agent/$SRC 'if !roamd \{' 'if false && !roamd {' "$NEW"
mut "F1 nowhere_login.sh no longer exports NOWHERE_GATEWAY_DEFAULT" vendor-common/bin/nowhere_login.sh \
  '\n  export NOWHERE_GATEWAY_DEFAULT\n' '\n' '--- FAIL: TestEveryDocumentedConfFlagIsExportedByADaemon'
mut "F2 the #keys push stops pinning NOWHERE_CARRY_ESSENTIAL, a suite spells a correct one" vendor-common/bin/nowhere_roamd.sh \
  'NOWHERE_CARRY_ESSENTIAL=0 (NOWHERE_CARRY_ESSENTIAL_MEDIA=0 \\\n\s+timeout -k 5 3600 "\$AGENT" push s3 "\$\{name\}#keys")' '\1' \
  '--- FAIL: TestScopeRestrictedFlagsArePinnedOffAtEveryOtherPush' \
  'NOWHERE_CARRY_ESSENTIAL=0 NOWHERE_CARRY_ESSENTIAL_MEDIA=0 "$AGENT" push s3 "${name}#keys"'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
