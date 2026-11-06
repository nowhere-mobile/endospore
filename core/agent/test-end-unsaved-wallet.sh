#!/usr/bin/env bash
# test-end-unsaved-wallet.sh [--mutate] -- runs the END-UNSAVED cases (end_unsaved_test.go, end_unsaved_wallet_test.go;
# NWP-20261021-01); --mutate re-runs them against end_unsaved.go with each guard broken in turn, restoring the file on
# exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d)
EU=end_unsaved.go
trap 'if [ -f "$W/$EU.orig" ]; then cp -f "$W/$EU.orig" "$EU"; fi; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestEndUnsaved_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
grep -E '^(--- |ok|FAIL|PASS)' <<<"$out" | tail -15
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp "$EU" "$W/$EU.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res
  python3 - "$EU" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$EU.orig" "$EU"; return; }
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp -f "$W/$EU.orig" "$EU"
}
mut "M1 the drop call removed" \
  "(lambda r: r[0] if r[1] == 1 else None)(re.subn(r'\t\tgoSafe\(\"end-unsaved-wallet\", func\(\) \{\n.*?\n\t\t\}\)\n', '\t\t_ = dropSE\n', s, count=1, flags=re.S))"
mut "M2 the drop moved before the commit" \
  "(lambda m: s.replace(m.group(0), '').replace('\thandleLogout(reply, dest)', m.group(0) + '\thandleLogout(reply, dest)', 1) if m and s.count('\thandleLogout(reply, dest)') == 1 else None)(re.search(r'\tif walletSaved \{\n.*?\n\t\}\n', s, re.S))"
# M3 is anchored on the wallet-not-restored arm: the push-licensed arm (NWP-20261101-05) sets creditLost first.
mut "M3 the drop made on the credit-lost arm" \
  "(lambda r: r[0] if r[1] == 1 else None)(re.subn(r'(\t\t\tcreditLost = true\n)(\t\t\} else if err != nil \{\n)', lambda m: m.group(1) + '\t\t\twalletSaved = true\n' + m.group(2), s))"
mut "M4 the drop made when the store said deleted" \
  "(lambda r: r[0] if r[1] == 1 else None)(re.subn(r'(\t\t\twalletSaved = true\n\t\t\}\n\t\})\n', lambda m: m.group(1) + ' else {\n\t\twalletSaved = true\n\t}\n', s, count=1))"
mut "M5 the walletSaved guard removed" \
  "(lambda r: r[0] if r[1] == 1 else None)(re.subn(r'\tif walletSaved \{\n', '\tif walletSaved || true {\n', s, count=1))"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
