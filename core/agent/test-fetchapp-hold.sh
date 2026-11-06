#!/usr/bin/env bash
# test-fetchapp-hold.sh [--mutate] -- runs the store Get seal-hold cases (fetchapp_hold_test.go; #53,
# NWP-20261117-20) with the materialise-window cases they build on (od_window_test.go): FETCH-APP opens the package's
# seal-hold lease after its entry checks, renews it while it runs, holds it for the install after an OK the chooser
# read and ends it on every other exit. --mutate re-runs them against catalog.go with each part broken in turn,
# restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=catalog.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestFetchAppHold|TestOdWindow' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res rc
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
def once(old, new):
    return s.replace(old, new, 1) if s.count(old) == 1 else None
def then(s2, old, new):
    return s2.replace(old, new, 1) if s2 is not None and s2.count(old) == 1 else None
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/$F.orig" "$F"
}
mut "H1 the lease is never opened" \
  "once('\tepoch := beginOdMaterialise(pkg, time.Now())\n', '\tepoch := func() uint64 { pendingReapMu.Lock(); defer pendingReapMu.Unlock(); return odWindowEpoch }()\n')"
mut "H2 the lease is never renewed" \
  "once('\tgoSafe(\"fetchapp-od-renew\", func() {\n\t\tdefer close(renewDone)\n\t\trenewOdWhile(pkg, epoch, stopRenew)\n\t})\n', '\tclose(renewDone)\n')"
mut "H3 a failed reply is settled as odInstalling" \
  "once('\t\tdefault:\n\t\t\toutcome = odFailed\n', '\t\tdefault:\n\t\t\toutcome = odInstalling\n')"
mut "H4 no defer: only the OK path settles" \
  "then(once('\tdefer settle()\n', ''), '\tendReply(fmt.Sprintf(\"OK %s %s\", pkg, fetchAppSigner(e)))\n', '\tendReply(fmt.Sprintf(\"OK %s %s\", pkg, fetchAppSigner(e)))\n\tsettle()\n')"
mut "H5 an OK the chooser read is not held for the install" \
  "once('\t\tsettleOdMaterialise(pkg, epoch, outcome, time.Now())\n', '\t\tif outcome != odInstalling {\n\t\t\tsettleOdMaterialise(pkg, epoch, outcome, time.Now())\n\t\t}\n')"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
