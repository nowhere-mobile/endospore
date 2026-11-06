#!/usr/bin/env bash
# test-money-recover-log.sh [--mutate] -- runs the cases for the two best-effort money paths (money_recover_log_test.go;
# NWP-20261027-16): a store read that fails inside maybePayRent or sealWalletBestEffort is recovered AND logged.
# --mutate re-runs them against a COPY of the package with each guard broken in turn. Each mutant must be CONVICTED by
# a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestBestEffortPanic|TestMaybePayRentLogsAFailedStoreRead|TestSealWalletBestEffortLogsAFailedSeal|TestRentGate|TestTelHandoff'

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/agent"
cp -a . "$P" || exit 2
fails=0
mut() { # mut <label> <file> <regex> <replacement>: exactly one substitution of <regex> in <file>, or it is INERT
  local label=$1 file=$2 res
  cp -f "$P/$file" "$W/orig" || return 1
  python3 - "$P/$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/orig" "$P/$file"
}

mut "P1 maybePayRent recovers silently again" main.go 'defer func\(\) \{ bestEffortPanic\("pay-rent", name, recover\(\)\) \}\(\)' 'defer func() { recover() }()'
mut "P2 sealWalletBestEffort recovers silently again" main.go 'defer func\(\) \{ bestEffortPanic\("roam-out wallet seal", name, recover\(\)\) \}\(\)' 'defer func() { recover() }()'
mut "P3 the generic line prints the recovered value" main.go '(skipped: unexpected failure \(details withheld\))\\n", what, name\)' '\1 %v\\n", what, name, r)'
mut "P4 the FAILED line prints the raw error" main.go 'logSafeStoreErr\(what, e\)' 'e.Error()'
[ "$fails" -eq 0 ] && echo "== all 4 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
