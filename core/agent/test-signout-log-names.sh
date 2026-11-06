#!/usr/bin/env bash
# test-signout-log-names.sh [--mutate] -- runs signout_log_names_test.go (NWP-20261127-03, docs/backlog.md, "The
# sign-out renewal's login.log line keeps the profile name in cleartext until the next reap or boot: it is written
# after the reap's log scrub"): the lines handleLogout's "logout-wallet" goroutine writes beside the reap -- the
# sign-out renewal's, the wallet step's and payRentGenRule's under the sign-out rule -- name only the user, and their
# error text holds no spelling of the profile's name. --mutate re-runs it against a COPY of the package with each
# guard broken in turn; the tree is never touched. Each mutant must be CONVICTED by a `--- FAIL` of the test named
# beside it; one that fails to apply or to compile, or that only another test catches, is a failure.
#   M1 the renewal's error line prints %q name again       M2 its error text is logSafeStoreErr alone
#   M3 the recover is bestEffortPanic(..., name, ...)      M4 the wallet step's error text is logSafeErrText alone
#   M5 payRentWho names the profile on the sign-out rule
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestSignoutLogNames' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <test that must convict it> <file> <python expression over s: the mutated text, or None>
  local label=$1 want=$2 file=$3 expr=$4 P res mrc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - "$file" "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); mrc=$?
  if ! score_mutant "$label" "$mrc" "$res"; then
    fails=$((fails+1))
  elif [[ "$res" != *"--- FAIL: $want"* ]]; then
    echo "  WRONG     $label -- no --- FAIL: $want"; fails=$((fails+1))
  fi
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
mut "M1 the renewal's error line prints %q name" TestSignoutLogNames_TheFreeTier402LineNamesOnlyTheUser logout_renew.go \
  "$(one "r'(case err != nil:\n\t\tfmt\.Fprintf\(os\.Stderr, \"\[logind\] signout-renewal )user %s: error \(%s\)(.{2}\", )uid,'" "lambda m: m.group(1) + '%q user %s: error (%s)' + m.group(2) + 'name, uid,'")"
mut "M2 the renewal's error text is logSafeStoreErr alone" TestSignoutLogNames_TheFreeTier402LineNamesOnlyTheUser logout_renew.go \
  "$(one "r'(case err != nil:\n\t\tfmt\.Fprintf\([^\n]*, )redactNameIn\((logSafeStoreErr\(\"signout-renewal\", err\)), name\)\)'" "lambda m: m.group(1) + m.group(2) + ')'")"
mut "M3 the recover is bestEffortPanic with the name" TestSignoutLogNames_EveryOtherBranchNamesOnlyTheUser/recover logout_renew.go \
  "$(one "r'signOutRenewalPanic\(uid, name, recover\(\)\)'" "'bestEffortPanic(\"signout-renewal\", name, recover())'")"
mut "M4 the wallet step's error text is logSafeErrText alone" TestSignoutLogNames_TheWalletStepErrorRedactsTheName logout_wallet.go \
  "$(one "r'redactNameIn\((logSafeErrText\(err\)), name\)'" "lambda m: m.group(1)")"
mut "M5 payRentWho names the profile on the sign-out rule" TestSignoutLogNames_PayRentLinesUnderTheSignOutRule/sign-out billing.go \
  "$(one "r'(if rule == renewSignOut \{\n\t\treturn )\"\(sign-out renewal\)\"'" "lambda m: m.group(1) + 'logProfile(name)'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
