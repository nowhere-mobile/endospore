#!/usr/bin/env bash
# test-media-restore-plan.sh [--mutate] -- runs media_after_gate_restore_test.go (NWP-20261125-03, backlog "A 179-second
# login, 95% of it bulk media restored INLINE before the gate opens", Q106 slice S2: mediaRestorePlan, the #media
# restore's split, docs/media-after-gate.md §5 item 1 and §8) with the ClaimsSeed pin of the same call line; --mutate
# re-runs them against a COPY of the package with one rule of the plan or its call broken in turn.
# Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestMediaRestorePlan|TestClaimsSeed_RestoreSeedsTheBareVaultOnly' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
mut() {
  local label="$1" f="$2" res rc
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 the split returns m with its full Chunks" media_after_gate.go \
  '\tout\.Chunks = pre ' '\tout.Chunks = m.Chunks '
mut "M2 the marker is written after cdcRestore" main.go \
  '\t\t\tskipped = restoreSkippingParked\(base, key, profile, mediaRestorePlan\(profile, pass, restoredHead, m\), dest\)\n' \
  '\t\t\tskipped = restoreSkippingParked(base, key, profile, m, dest)\n\t\t\t_ = mediaRestorePlan(profile, pass, restoredHead, m)\n'
mut "M3 the failed-marker arm returns the split" media_after_gate.go \
  'whole set restores inline \(NWP-20261125-03\)"\)\n\t\treturn m\n' \
  'whole set restores inline (NWP-20261125-03)")\n\t\tout := m\n\t\tout.Chunks = pre\n\t\treturn out\n'
mut "M4 the scope check is dropped" media_after_gate.go \
  'if !mediaAfterGateOn\(\) \|\| !isSharedMediaScope\(profile\) \{' 'if !mediaAfterGateOn() {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
