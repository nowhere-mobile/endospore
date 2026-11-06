#!/usr/bin/env bash
# test-kdf-forget.sh [--mutate] -- runs the KDF-cache cases (kdf_forget_test.go; NWP-20261107-04, dn-1106 #1): the login
# daemon forgets its KDF cache at every session end. --mutate re-runs them against a COPY of the package with each
# call site broken in turn; the tree is never touched. Each mutant must be CONVICTED by a real `--- FAIL`; one that
# fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestKDFForget' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res
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
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
mut "F1 the CLEAN-STORAGE call removed" main.go \
  "$(one "r'\t\tif n, err := strconv.Atoi\(uid\); err == nil && n >= 10 \{\n\t\t\tforgetSessionKeys\(\"reap\"\)\n\t\t\}\n'" "''")"
mut "F2 the logout-wallet call removed" main.go \
  "$(one "r'\t\t\tforgetSessionKeys\(\"sign-out wallet published\"\)\n'" "''")"
mut "F3 the logout-wallet call moved before the step" main.go \
  "$(one "r'(\t\tgoSafe\(\"logout-wallet\", func\(\) \{\n)(\t\t\tlogoutRenewStep[^\n]*\n)(\t\t\tlogoutWalletStep[^\n]*\n)(\t\t\tforgetSessionKeys[^\n]*\n)'" "lambda m: m.group(1) + m.group(2) + m.group(4) + m.group(3)")"
mut "F4 the END-UNSAVED call removed" end_unsaved.go \
  "$(one "r'\t\t\tforgetSessionKeys\(\"end-unsaved wallet published\"\)[^\n]*\n'" "''")"
mut "F5 the final BLANK arm's call removed" main.go \
  "$(one "r'(fmt\.Fprint\(conn, \"BLANK\\\\n\"\)\n\t\tscheduleFailedSigninScrub\(dest\) // NWP-20261027-02\n)\t\t// dn-1106 #1[^\n]*\n\t\tforgetSessionKeys\(\"blank sign-in\"\)\n'" "lambda m: m.group(1)")"
mut "F6 a call added to the ERR-TIMEOUT arm" main.go \
  "$(one "r'(\t\tfmt\.Fprint\(conn, \"ERR-TIMEOUT\\\\n\"\)\n)'" "lambda m: m.group(1) + '\t\tforgetSessionKeys(\"blank sign-in\")\n'")"
mut "F7 forgetSessionKeys made a no-op" main.go \
  "$(one "r'\tderiveKeyForget\(\)\n(\tfmt\.Fprintf\(os\.Stderr, \"\[logind\] KDF cache forgotten)'" "lambda m: m.group(1)")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
