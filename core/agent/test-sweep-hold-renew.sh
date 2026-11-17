#!/usr/bin/env bash
# test-sweep-hold-renew.sh [--mutate] -- runs the Auto sweep hold-renewal tests (sweep_hold_renew_test.go,
# NWP-20261204-05) with the materialise-window and auto-sweep cases they build on: a materialise's fetch and a
# RESTORE-ODDATA's odrestore renew the sweep's lease while their worker op is in flight, so "until setup finishes"
# holds through a step of any length. --mutate re-runs them with od_window.go, app_code.go, auto_sweep.go or
# catalog.go broken in turn, restoring all four on exit. Each mutant must be CONVICTED by a `--- FAIL`; one that fails
# to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(od_window.go app_code.go auto_sweep.go catalog.go)
trap 'for f in "${FILES[@]}"; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'SweepHold|OdRestoreNoStray|StoreGetDoesNotRenew|CappedChoiceStill|OdWindow|AutoSweep' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
restore() { local f; for f in "${FILES[@]}"; do cp -f "$W/$f.orig" "$f"; done; }
# conv <label>: run the suite against the mutated files, then restore them.
conv() {
  local res rc
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <file> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$2" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
# Convicted by TestSweepHoldOutlivesALongDataRestore.
mut "M1 the odrestore renews nothing while it runs" app_code.go \
  '\t\trenewOdWhileSweep\(pkg, epoch, stopRenew\)\n' '\t\t_ = epoch\n\t\t<-stopRenew\n'
# Convicted by TestSweepHoldOutlivesALongDataRestore and TestSweepHoldOutlivesALongFetch.
mut "M2 a step's renewal never renews the sweep" od_window.go \
  '(if extendOdLease\(pkg, epoch, now, odFetchLease\) \{\n)\t\t\t\trenewAutoSweep\(now\)\n' '\1'
# Convicted by TestSweepHoldOutlivesALongFetch.
mut "M3 the materialise's fetch back on renewOdWhile" app_code.go \
  'renewOdWhileSweep\(pkg, epoch, stop\)' 'renewOdWhile(pkg, epoch, stop)'
# Convicted by TestOdRestoreNoStrayRenewal.
mut "M4 the restore closes the renewal's stop without waiting for it" app_code.go \
  '\t\tclose\(stopRenew\)\n\t\t<-renewDone\n' '\t\tclose(stopRenew)\n'
# Convicted by TestStoreGetDoesNotRenewTheSweep.
mut "M5 a store Get renews the sweep" catalog.go \
  'renewOdWhile\(pkg, epoch, stopRenew\)' 'renewOdWhileSweep(pkg, epoch, stopRenew)'
# Convicted by TestSweepHoldLapsesAfterTheLastStep (and TestAutoSweepRenewOnlyExtendsALiveLease).
mut "M6 renewAutoSweep revives a lapsed lease" auto_sweep.go \
  'if !autoSweepUntil\.IsZero\(\) && now\.Before\(autoSweepUntil\) \{\n\t\tautoSweepUntil = now\.Add\(autoSweepLease\)' \
  'if true {\n\t\tautoSweepUntil = now.Add(autoSweepLease)'
# Convicted by TestCappedChoiceStillLetsOneSealThrough.
mut "M7 a renewal moves the anchor to now" od_window.go \
  '(\t\t\t\trenewAutoSweep\(now\)\n)' '\1\t\t\t\tpendingReapMu.Lock()\n\t\t\t\tsealsHeldSince = now\n\t\t\t\tpendingReapMu.Unlock()\n'
# Convicted by TestSweepHoldStaleEpochDoesNotRenew.
mut "M8 a stale epoch's tick still renews the sweep" od_window.go \
  '\t\t\tif extendOdLease\(pkg, epoch, now, odFetchLease\) \{\n\t\t\t\trenewAutoSweep\(now\)\n\t\t\t\}\n' \
  '\t\t\textendOdLease(pkg, epoch, now, odFetchLease)\n\t\t\trenewAutoSweep(now)\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
