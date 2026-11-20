#!/usr/bin/env bash
# test-coldde-evidence.sh [--mutate] -- the last cold-lock resume's re-created accounts_de.db figures reach an
# in-session issue report (NWP-20261206-23, backlog: During a cold lock, AccountManagerService's own handler thread
# re-creates an EMPTY `accounts_de.db` for the stopped user). roam.log's lines fall out of a report's trimmed tail;
# status keys never do. roamd's de_unpark writes one line to $STATE/coldde-unpark
# (v=1 found=<0|1> after_park_s=<n|na> db_bytes=<n|na> wal_bytes=<n|na> emails=<n|na> ss_fds=<n|na>
# pkgs_delta_s=<n|na> pkgr_delta_s=<n|na>); coldde_evidence.go reads it into eight coldde_* status keys, at session
# scope only, because whether and when a session's account file came back is a profile fact.
#
# This suite runs coldde_evidence_test.go. --mutate breaks each guard in turn on a COPY of the package; each mutant must
# be CONVICTED by a real `--- FAIL`. One that fails to apply or compile is a failure. There is no mutant for the
# 256-byte read cap: no line the regexp accepts reaches 256 bytes, so removing the cap is unobservable.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 180s -run 'TestColdDeUnparkStatus|TestSessionReportCarriesColdDeKeys' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

echo; echo "== mutants (each MUST be convicted) =="
fails=0
# mut <label> <test> <file> <regex> <replacement>: exactly one substitution in a package copy; needs a real
# `--- FAIL: <test>`
mut() {
  local label=$1 test=$2 file=$3 P res
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P" || { fails=$((fails+1)); return; }
  python3 - "$P/$file" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && "${RUN[@]}" 2>&1)
  if grep -qE "^\s*--- FAIL: $test " <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  rm -rf "$P"
}

LOOP='\n\t\tfor k, v := range coldDeUnparkStatus\(filepath\.Join\(loginStateDir\(\), coldDeUnparkFile\)\) \{\n\t\t\tstatus\[k\] = v\n\t\t\}'
mut "C1 the report loop removed (TestSessionReportCarriesColdDeKeys)" TestSessionReportCarriesColdDeKeys \
  report_issue.go "$LOOP" ''
mut "C2 the loop moved outside if !deviceScope (TestSessionReportCarriesColdDeKeys, its deviceScope=true half)" \
  TestSessionReportCarriesColdDeKeys report_issue.go "$LOOP"'(\n\t\})' \
  '\1\n\tfor k, v := range coldDeUnparkStatus(filepath.Join(loginStateDir(), coldDeUnparkFile)) {\n\t\tstatus[k] = v\n\t}'
mut "C3 the regexp's end anchor dropped (TestColdDeUnparkStatusRefuses: an extra trailing field)" \
  TestColdDeUnparkStatusRefuses coldde_evidence.go '\\n\?\$`\)' '\\n?`)'
mut "C4 the delta's -? dropped (TestColdDeUnparkStatusParses: a negative delta)" TestColdDeUnparkStatusParses \
  coldde_evidence.go 'pkgs_delta_s=\(-\?' 'pkgs_delta_s=('
mut "C5 a missing file returns unreadable (TestColdDeUnparkStatusMissing)" TestColdDeUnparkStatusMissing \
  coldde_evidence.go '(errors\.Is\(err, fs\.ErrNotExist\) \{\n\t\treturn )map\[string\]string\{\}' '\1unreadable'
mut "C6 coldde_emails misnamed coldde_email (TestColdDeUnparkStatusParses)" TestColdDeUnparkStatusParses \
  coldde_evidence.go '"coldde_emails": ' '"coldde_email":  '
[ "$fails" -eq 0 ] && echo "== all 6 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
