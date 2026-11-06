#!/usr/bin/env bash
# test-claim-labels.sh [--mutate] -- runs claim_labels_test.go (NWP-20261125-06, h54 #1; backlog row "The unit label
# embeds the unit id, so the device-naming rule decided in `NWP-20260912-01` cannot ship") with the claim tests it must
# not break. --mutate re-runs them with each part of the holder-label rule broken in turn (app_claim.go or main.go),
# restoring both files on exit. Each mutant must be CONVICTED (a real `--- FAIL`); one that fails to apply, or fails to
# compile, counts as a failure. The task's "the seed ignores labels" mutant has no target: the moderator ruling of
# 2026-11-03 keeps the sign-in seed two columns, and TestClaimLabels_SeedStaysTwoColumns pins that.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
cp main.go "$W/main.go.orig"
cp app_claim.go "$W/app_claim.go.orig"
trap 'cp -f "$W/main.go.orig" main.go; cp -f "$W/app_claim.go.orig" app_claim.go; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestClaimLabels_|TestClaimsSeed|TestClaims_AScopedSeal|TestWriteClaimsOut' .)

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
mut "M1 another unit's label is carried after its claims lapse" app_claim.go \
  'if u != unit && holds\[u\] \{' \
  'if u != unit {'
mut "M2 this unit's label is kept while it holds nothing" app_claim.go \
  'if holds\[unit\] && validDeviceLabel\(label\) \{' \
  'if validDeviceLabel(label) {'
mut "M3 the != own compare dropped" app_claim.go \
  'if t := strings\.TrimSpace\(l\); t != own \{' \
  'if t := strings.TrimSpace(l); t != "" {'
mut "M4 a scoped seal writes the labels" main.go \
  '(\n\tmj, _ := json\.Marshal\(chunkManifest\{)' \
  '\n\tif labelsIdx == nil {\n\t\tlabelsIdx = map[string]string{claimUnit: deviceLabel()}\n\t}\1'
mut "M5 the seal writes no names" main.go \
  'holderNames\(labelsIdx, ownLabel\)\)' \
  'nil)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
