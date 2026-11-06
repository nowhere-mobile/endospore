#!/usr/bin/env bash
# test-fetchapp-log.sh [--mutate] -- runs the FETCH-APP log cases (fetchapp_log_test.go; NWP-20261113-26): one start
# line before the first download, a progress line at most once per interval, one done line on every exit, and no
# package, label or URL in any of them. --mutate re-runs them against catalog.go with each part broken in turn,
# restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile
# is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=catalog.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestFetchAppLog' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <label> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 res rc
  python3 - "$F" "$2" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import sys
p, expr = sys.argv[1:3]
s = open(p).read()
def once(old, new, t=None):
    t = s if t is None else t
    return t.replace(old, new, 1) if t.count(old) == 1 else None
def then(t, old, new):
    return None if t is None else once(old, new, t)
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/$F.orig" "$F"
}
mut "L1 a failed download prints no done line" \
  "then(once('endReply(\"ERR-UNVERIFIED\")', 'fmt.Fprint(conn, \"ERR-UNVERIFIED\\\\n\")'), 'endReply(\"ERR-FETCH\")', 'fmt.Fprint(conn, \"ERR-FETCH\\\\n\")')"
mut "L2 the OK reply prints no done line" \
  "once('endReply(fmt.Sprintf(\"OK %s %s\", pkg, fetchAppSigner(e)))', 'fmt.Fprintf(conn, \"OK %s %s\\\\n\", pkg, fetchAppSigner(e))')"
mut "L3 the start line prints the package" \
  "once('start: %d apk(s), %d bytes (NWP-20261113-26)\\\\n\", len(e.APKs), total)', 'start: %s %d apk(s), %d bytes (NWP-20261113-26)\\\\n\", pkg, len(e.APKs), total)')"
mut "L4 no progress line is ever printed" \
  "once('now.Sub(last) >= fetchAppProgressEvery', 'false && now.Sub(last) >= fetchAppProgressEvery')"
mut "L5 a progress line on every read" \
  "once('now.Sub(last) >= fetchAppProgressEvery', 'now.Sub(last) >= 0')"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
