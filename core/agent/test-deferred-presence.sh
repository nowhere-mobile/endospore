#!/usr/bin/env bash
# test-deferred-presence.sh [--mutate] -- runs the h51 #2 deferred-presence cases (deferred_presence_test.go and the
# #84 P3d carry; NWP-20261207-02); --mutate re-runs them with the restore, the check, the seal guard, the refusal class
# the late step, the stale-check guard, the probes' fixed-token logging and the unreadable-list refusal broken in turn, restoring every mutated file on exit. Each mutant must be CONVICTED by a real
# `--- FAIL` of the test named in its label; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go deferred_presence.go end_unsaved.go)
trap 'for f in "${FILES[@]}"; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestRestoreListsDeferred|TestSettleDeferred|TestSealRefusesMissing|TestSealWithoutPresence|TestPendingHashNotInHead|TestSealRefusesWhenPendingListUnreadable|TestDeferredRefusals|TestRoamInLateWorkSettles|TestPresenceSettlesOnly|TestOldPresenceCheck|TestPresenceProbeLogsNoChunkHash|TestSealCarriesDeferredForward' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None> <test that must fail>...
  local label=$1 file=$2 expr=$3 res rc t
  shift 3
  python3 - "$file" "$expr" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$file.orig" "$file"; return; }
import sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  cp -f "$W/$file.orig" "$file"
  if ! score_mutant "$label" "$rc" "$res"; then fails=$((fails+1)); return; fi
  for t in "$@"; do
    if [[ "$res" != *"--- FAIL: $t "* ]]; then
      echo "    but $t did not fail -- the mutant was not convicted by the named assertion"
      fails=$((fails+1))
    fi
  done
}
SEED='\tfor _, h := range m.Chunks {\n\t\tblobCacheAdd(h)\n\t}\n'
STEP='\t\t\tfunc(lw *lateWork) {\n\t\t\t\tif lw.mayWrite() {\n\t\t\t\t\tgoSafe(\"deferred-presence\", func() {\n\t\t\t\t\t\tsettleSignInPresence(\"s3\", lateState, lateCache, lateName, latePass, lw.mayWrite)\n\t\t\t\t\t})\n\t\t\t\t}\n\t\t\t},\n'
CAPT='\t\tlateState, lateCache := os.Getenv(\"NOWHERE_STATE\"), workerBlobCachePath() // the paths of step 6, read now\n'
mut "P1 the restore seeds the deferred chunks again" main.go \
  "s.replace('$SEED', '$SEED\tfor _, d := range m.Deferred {\n\t\tfor _, h := range d.Chunks {\n\t\t\tblobCacheAdd(h)\n\t\t}\n\t}\n', 1) if s.count('$SEED') == 1 else None" \
  TestRestoreListsDeferredDoesNotSeed
mut "P2 an absent answer counted present" deferred_presence.go \
  "s.replace('default:\n\t\t\t\t\tres[i] = presMissing\n', 'default:\n\t\t\t\t\tres[i] = presPresent\n', 1) if s.count('res[i] = presMissing\n') == 1 else None" \
  TestSettleDeferredPresence TestSealRefusesMissingDeferredPiece
mut "P3 a probe error counted present" deferred_presence.go \
  "s.replace('res[i] = presUnknown //', 'res[i] = presPresent //', 1) if s.count('res[i] = presUnknown //') == 1 else None" \
  TestSettleDeferredPresence
mut "P4 the seal guard removed" main.go \
  "s.replace('; dm > 0 || du > 0 {', '; false && (dm > 0 || du > 0) {', 1) if s.count('; dm > 0 || du > 0 {') == 1 else None" \
  TestSealRefusesMissingDeferredPiece
mut "P5 an absent pending list read as nothing pending" deferred_presence.go \
  "s.replace('listed = want //', 'return 0, 0 //', 1) if s.count('listed = want //') == 1 else None" \
  TestSealWithoutPresenceFileChecksTheHead
mut "P6 deferred-missing made final" end_unsaved.go \
  "s.replace('case \"shrink\", \"no-receipt\",', 'case \"deferred-missing\", \"shrink\", \"no-receipt\",', 1) if s.count('case \"shrink\", \"no-receipt\",') == 1 else None" \
  TestDeferredRefusalsAreRetryClass
mut "P7 the late sign-in step removed" main.go \
  "s.replace('$STEP', '', 1).replace('$CAPT', '', 1) if s.count('$STEP') == 1 and s.count('$CAPT') == 1 else None" \
  TestRoamInLateWorkSettlesPresence
mut "P8 every deferred-presence-* file settled" deferred_presence.go \
  "s.replace('paths := deferredPresencePaths(stateDir, profile, pass)', 'paths, _ := filepath.Glob(filepath.Join(stateDir, \"deferred-presence-*[0-9a-f]\"))', 1) if s.count('paths := deferredPresencePaths(stateDir, profile, pass)') == 1 else None" \
  TestPresenceSettlesOnlyThisProfile
mut "P9 the cap probe goes back to capRefExists" deferred_presence.go \
  "s.replace('return presenceCapExists(key)', 'return capRefExists(key)', 1) if s.count('return presenceCapExists(key)') == 1 else None" \
  TestPresenceProbeLogsNoChunkHash
mut "P10 the S3 probe goes back to s3ExistsErr" deferred_presence.go \
  "s.replace('return presenceS3Exists(key)', 'return s3ExistsErr(key)', 1) if s.count('return presenceS3Exists(key)') == 1 else None" \
  TestPresenceProbeLogsNoChunkHash
mut "P11 an old check publishes into a new generation" deferred_presence.go \
  "s.replace(' || pendingGen(path) != gen', ' || false && pendingGen(path) != gen', 1) if s.count(' || pendingGen(path) != gen') == 1 else None" \
  TestOldPresenceCheckDoesNotClearNewSignIn
mut "P12 an ended session still publishes" deferred_presence.go \
  "s.replace(' || !lateMayWrite(mayWrite) {\n\t\t\t\treturn err //', ' {\n\t\t\t\treturn err //', 1) if s.count(' || !lateMayWrite(mayWrite) {\n\t\t\t\treturn err //') == 1 else None" \
  TestOldPresenceCheckDoesNotClearNewSignIn
mut "P13 an unreadable pending list settles as nothing unchecked" deferred_presence.go \
  "s.replace('return 0, 0, len(only) // nothing probed', 'return 0, 0, 0 // nothing probed', 1) if s.count('return 0, 0, len(only) // nothing probed') == 1 else None" \
  TestSealRefusesWhenPendingListUnreadable
mut "P14 a vanished pending list settles as nothing unchecked" deferred_presence.go \
  "s.replace('return 0, 0, len(only) // no list:', 'return 0, 0, 0 // no list:', 1) if s.count('return 0, 0, len(only) // no list:') == 1 else None" \
  TestSealRefusesWhenPendingListUnreadable
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
