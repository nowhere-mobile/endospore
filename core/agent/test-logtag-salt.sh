#!/usr/bin/env bash
# test-logtag-salt.sh [--mutate] -- runs logtag_salt_test.go (NWP-20261127-16): every process of one boot tags a
# profile alike. loadOrMintLogTagSalt publishes a new <NOWHERE_STATE>/logtag.salt by os.Link, so the first writer
# wins and every other caller adopts the file's bytes; a cut file is replaced once and read back; no temp file is
# left. --mutate re-runs the cases against main.go with each rule broken in turn, and restores main.go on exit.
# Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply (INERT) or to compile (BROKEN) is a
# failure. No mutant needs a thread interleaving to be convicted: the link race is forced by a test hook.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 180s -run 'TestLogTagSalt|TestEveryGoroutineGoesThroughGoSafe' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig" || exit 2
fails=0
mut() { # mut <label> <python regex> <replacement>: exactly one substitution in main.go, or INERT
  local label=$1 res rc
  python3 - main.go "$2" "$3" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
if len(re.findall(pat, s)) != 1: sys.exit(1)
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  cp -f "$W/main.go.orig" main.go
}

mut "M1 os.Link replaced by a plain write of the final path" \
  'if err := os\.Link\(tmp, final\); err != nil \{' 'if err := os.WriteFile(final, salt, 0o600); err != nil {'
mut "M2 the loser of the link race keeps its own bytes" \
  '(if errors\.Is\(err, fs\.ErrExist\) \{\n\t+)return readSalt\(\)' '\g<1>return salt, true'
mut "M3 the cut-file branch dropped" \
  '\tcase err == nil:\n\t\tcut = true\n' ''
mut "M4 the temp file not removed" \
  '\tdefer os\.Remove\(tmp\)\n' ''
[ "$fails" -eq 0 ] && echo "== all 4 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
