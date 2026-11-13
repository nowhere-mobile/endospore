#!/usr/bin/env bash
# test-sync-interval-default.sh [--mutate] -- runs sync_interval_test.go (NWP-20261202-19; backlog row "The periodic
# save starts 2 minutes after the last one ends, although a save takes 3-10 minutes, and the choices offered go down
# to 30 seconds") with the claim tests it must not break. The periodic save defaults to 15 minutes, a stored
# /data/nowhere/sync-interval still overrides it (a value the gate no longer offers still applies, clamped to
# [15, 86400]), and a claim lives 60 minutes, four default cycles. --mutate re-runs them with each part broken in turn
# (main.go or app_claim.go), restoring both files on exit. Each mutant must be CONVICTED (a real `--- FAIL`); one
# that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp main.go "$W/main.go.orig"
cp app_claim.go "$W/app_claim.go.orig"
trap 'cp -f "$W/main.go.orig" main.go; cp -f "$W/app_claim.go.orig" app_claim.go; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestSyncIntervalDefault|TestClampSyncInterval|TestClaim_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label="$1" file="$2" mout mrc
  python3 - "$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$mout" || fails=$((fails+1))
  cp -f "$W/$file.orig" "$file"
}
# Convicted by TestSyncIntervalDefault_FifteenMinutes (the 900 constant and the no-file case).
mut "M1 the default is 2 minutes again" main.go \
  'const syncIntervalDefault = 900\n' \
  'const syncIntervalDefault = 120\n'
# Convicted by TestSyncIntervalDefault_FifteenMinutes (the stored-30, stored-10 and stored-1800 cases).
mut "M2 the default wins over a stored value" main.go \
  'if b, err := os\.ReadFile\(syncIntervalPath\); err == nil \{' \
  'if b, err := os.ReadFile(syncIntervalPath); false && err == nil {'
# Convicted by TestClaim_TTLOutlastsSeveralSyncCycles (claimTTL >= 4 * syncIntervalDefault).
mut "M3 a claim lapses after 15 minutes again" app_claim.go \
  'const claimTTL int64 = 60 \* 60\n' \
  'const claimTTL int64 = 15 * 60\n'
# Convicted by TestSyncIntervalDefault_FifteenMinutes (the stored-30 case: a choice no longer offered still applies).
mut "M4 a stored value is raised to at least 2 minutes" main.go \
  '(n > 0 \{\n\t\t\t)(return clampSyncInterval\(n\))' \
  '\1if n < 120 {\n\t\t\t\tn = 120\n\t\t\t}\n\t\t\t\2'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
