#!/usr/bin/env bash
# test-health-fix-age.sh [--mutate] -- runs health_fix_age_test.go and the mergeHealth pins (NWP-20261205-03: an
# in-session issue report carries, per health rule with a Fix, fix_age=<s> since this session's last Fix, or fix=none);
# --mutate re-runs them against a COPY of the package with each part broken in turn. Each mutant must be CONVICTED by
# a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'HealthFixAge|MergeHealth|HealthReachesTheIssueReport' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement> <the test that must convict it>: apply to the copy, run the tests
# there, require that test's own `--- FAIL`, then restore the file.
mut() {
  local label="$1" f="$2" conv="$5" res
  cp "$P/$f" "$W/orig.go"
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p,encoding='utf-8').read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w',encoding='utf-8').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *"--- FAIL: $conv"* ]]; then echo "  convicted $label (by $conv)"
    else echo "  SURVIVED  $label (wanted --- FAIL: $conv)"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "A1 the Fix field is omitted from the value" health_check.go \
  'healthStatusValue\(&healthState\.results\[i\], now\) \+ fixes\[rule\.id\]' \
  'healthStatusValue(&healthState.results[i], now)' TestHealthFixAgeRecorded
mut "A2 healthFixAge resets the Fix state for the report's uid" health_fix.go \
  '(\tat, ok := healthFixState\.at\[id\]\n)(\tif !ok \|\| healthFixState\.uid != uid \{)' \
  '\thealthFixForUIDLocked(uid)\n\1\2' TestHealthFixAgeOtherUID
mut "A3 a Fix in the future prints a negative age" health_fix.go \
  'return healthClampS\(now\.Sub\(at\)\), true' 'return int64(now.Sub(at) / time.Second), true' TestHealthFixAgeClockBack
mut "A4 fix=none is never written" health_check.go \
  'fixes\[rule\.id\] = " fix=none"' 'fixes[rule.id] = ""' TestHealthFixAgeNone
mut "A5 every rule gets the Fix field, not only a healthFixes key" health_check.go \
  'if _, hasFix := healthFixes\[rule\.id\]; !hasFix \{\n\t\t\tcontinue\n\t\t\}\n\t\t' '' TestHealthFixAgeNoFixRule
mut "A6 the age is read for the recorded uid, not the report's" health_check.go \
  'healthFixAge\(uid, rule\.id, now\)' 'healthFixAge(healthFixState.uid, rule.id, now)' TestHealthFixAgeOtherUID
mut "A7 mergeHealth ignores deviceScope" health_check.go \
  'if deviceScope \|\| status == nil \{' 'if status == nil {' TestHealthFixAgeGateScope
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
