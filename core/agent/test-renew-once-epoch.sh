#!/usr/bin/env bash
# test-renew-once-epoch.sh [--mutate] -- runs renew_once_epoch_test.go (NWP-20261129-22, decision "seventeen answers to
# harvest 59 ...", #9): the periodic and manual seals renew the whole footprint at most once per epoch, the sign-out
# rule and renewalDue do not change. --mutate re-runs it against a COPY of the package with each guard broken in turn;
# the tree is never touched. Each mutant must be CONVICTED by a `--- FAIL` of the tests it names; one that fails to
# apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestRenewOnce|TestSignOutRenewal_ThePeriodicRuleIsUnchanged|TestRenewalStillRunsWhenRentIsDue' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <space-separated tests that must fail> <python expression over s, None when it does not apply>
  local label=$1 tests=$2 expr=$3 P res mrc t nl=$'\n'
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - billing.go "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); mrc=$?
  if score_mutant "$label" "$mrc" "$res"; then
    for t in $tests; do
      if [[ "$nl$res" != *"$nl--- FAIL: $t "* ]]; then
        echo "  NOT NAMED $label -- no --- FAIL line for $t"
        fails=$((fails+1))
      fi
    done
  else
    fails=$((fails+1))
  fi
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
mut "Q1 dueBy's periodic arm is renewalDue again" TestRenewOnce_E1_LapsedShortWallet \
  "$(one "r'(\t\treturn signOutRenewalDue\(w, nowEpoch\)\n\t\}\n\treturn )periodicRenewalDue\(w, nowEpoch\)'" "lambda m: m.group(1) + 'renewalDue(w, nowEpoch)'")"
mut "Q2 the gate is <= instead of <" TestRenewOnce_E1_LapsedShortWallet \
  "$(one "r'(func periodicRenewalDue\(w \*Wallet, nowEpoch int64\) bool \{\n\treturn w\.RenewedEpoch )< nowEpoch'" "lambda m: m.group(1) + '<= nowEpoch'")"
mut "Q3 the sign-out rule is given the same gate" TestSignOutRenewal_ThePeriodicRuleIsUnchanged \
  "$(one "r'(func signOutRenewalDue\(w \*Wallet, nowEpoch int64\) bool \{\n\treturn w\.RenewedEpoch < nowEpoch )\|\| renewalDue'" "lambda m: m.group(1) + '&& renewalDue'")"
mut "Q4 renewalDue itself is gated" "TestRenewalStillRunsWhenRentIsDue TestSignOutRenewal_ThePeriodicRuleIsUnchanged" \
  "$(one "r'(func renewalDue\(w \*Wallet, nowEpoch int64\) bool \{\n\treturn )(w\.PaidThrough <= nowEpoch \|\| nowEpoch-w\.RenewedEpoch >= renewEveryEpochs \|\| w\.planPending\(\))'" "lambda m: m.group(1) + 'w.RenewedEpoch < nowEpoch && (' + m.group(2) + ')'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
