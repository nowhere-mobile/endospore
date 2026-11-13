#!/usr/bin/env bash
# test-staged-claim-retry.sh [--mutate] -- a create's staged claim is retried from a later save (h60 #17,
# NWP-20261201-23): over an unreadable stored copy finishStagedClaim publishes nothing and keeps the file, and the
# profile's next successful bare-vault seal publishes it merged against the stored copy.
# Plain: the focused set. --mutate copies the package into the temp root for every mutant, applies the mutant to THAT
# copy and runs the same focused set there; each must be CONVICTED by its named `--- FAIL`. The working tree is never
# edited. A mutant that fails to apply (its literal must occur exactly once) or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='StagedClaimRetry_'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>... (old must occur exactly once)
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want d
  shift 4
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R "$SRC/." "$d/"
  python3 - "$d/$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(cd "$d" && go test -count=1 -run "$FOCUS" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  rm -rf "$d"
}
mut "M1 the unreadable arm publishes anyway" main.go \
  $'stored, readable := storedWalletForPublish("s3", name, pass, dk)\n\tif !readable {' \
  $'stored, readable := storedWalletForPublish("s3", name, pass, dk)\n\t_ = readable\n\tif false {' \
  TestStagedClaimRetry_AnUnreadableStoredCopyPublishesNothing
mut "M2 the pre-merge is dropped" main.go \
  'toPublish = walletForPublish(stored, &staged, seen)' 'toPublish = &staged' \
  TestStagedClaimRetry_ThePublishIsMergedBeforeTheSecondRead
mut "M3 the # guard is removed" main.go \
  $'func retryStagedClaimAfterSave(profile, pass string) (published bool) {\n\tif strings.Contains(profile, "#") {' \
  $'func retryStagedClaimAfterSave(profile, pass string) (published bool) {\n\tif false {' \
  TestStagedClaimRetry_OnlyABareVaultSaveRetries
mut "M4 the retry's seen-set guard is removed" main.go \
  'if retry && stored != nil && seen == nil {' 'if false {' \
  TestStagedClaimRetry_AnUnusableSeenSetRefusesTheRetryOnly
mut "M5 the push case's call is deleted" main.go \
  $'\t\tretryStagedClaimAfterSave(os.Args[3], os.Args[4])\n' '' \
  TestStagedClaimRetry_PushRetriesAfterTheRefusalExit
mut "M6 the retry's recover is removed" main.go \
  $'\t\tif recover() != nil {\n\t\t\tpublished = false\n\t\t}\n' '' \
  TestStagedClaimRetry_AStoreFailureStaysInsideTheRetry
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
