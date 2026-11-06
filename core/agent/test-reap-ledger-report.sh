#!/usr/bin/env bash
# test-reap-ledger-report.sh [--mutate] -- runs reap_ledger_report_test.go (NWP-20261107-14, Q143): an issue report carries
# the reap ledger's counts per class (reap_ledger_rows / _classes / _userdir) at both scopes and never a uid, a time or
# a name; the reap retry's gaveup and retried rows count as their own classes (NWP-20261114-25, #67). --mutate re-runs the cases against a COPY of the package with each guard broken in turn. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestReapLedgerReport'

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <regex> <replacement>: exactly one substitution of <regex> in <file> of a package copy, or INERT
  local label=$1 file=$2 P res
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P" || { fails=$((fails+1)); return; }
  python3 - "$P/$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; }
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
  rm -rf "$P"
}

mut "N1 boot rows counted as other" reap_ledger_report.go 'return "boot"' 'return "other"'
mut "N2 recheck counted as other" reap_ledger_report.go 'case "clean", "gaveup", "husk", "recheck", "residue", "retried":' 'case "clean", "gaveup", "husk", "residue", "retried":'
mut "N3 the userdir key counts anchor:ok" reap_ledger_report.go 'case strings\.HasPrefix\(fl, "userdir=anchor:timeout"\):' 'case strings.HasPrefix(fl, "userdir=anchor:timeout"), strings.HasPrefix(fl, "userdir=anchor:ok"):'
mut "N4 the uid copied into a key" reap_ledger_report.go 'strconv\.Itoa\(rows\)' 'strconv.Itoa(rows) + " " + strings.Join(strings.Fields(string(b)), " ")'
mut "N5 only the device scope carries the keys" report_issue.go 'range reapLedgerCounts\(reapLedgerPath\)' 'range map[bool]map[string]string{true: reapLedgerCounts(reapLedgerPath)}[deviceScope]'
mut "N6 the unreadable case answers zero counts" reap_ledger_report.go '"unreadable: " \+ err\.Error\(\)' '"0"'
mut "N7 gaveup counted as other" reap_ledger_report.go 'case "clean", "gaveup", "husk",' 'case "clean", "husk",'
mut "N8 retried counted as other" reap_ledger_report.go '"residue", "retried":' '"residue":'
mut "N9 the gaveup and retried counts swapped" reap_ledger_report.go 'n\["gaveup"\](.*)n\["retried"\]' 'n["retried"]\1n["gaveup"]'
mut "N10 tries= copied into the value" reap_ledger_report.go 'n\["retried"\]\),' 'n["retried"]) + " " + strings.Join(func() (t []string) { for _, fl := range strings.Fields(string(b)) { if strings.HasPrefix(fl, "tries=") { t = append(t, fl) } }; return }(), " "),'
[ "$fails" -eq 0 ] && echo "== all 10 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
