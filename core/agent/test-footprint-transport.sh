#!/usr/bin/env bash
# test-footprint-transport.sh [--mutate] -- runs footprint_transport_test.go (NWP-20261117-14): a store read that fails
# in transport inside one of the footprint's manifest reads raises errStoreUnreachable like its head reads, a manifest
# that arrives damaged is still skipped, payRent does not renew a short set, and installHeadroom fails open.
# --mutate re-runs the cases against copies of billing.go and scope_rekey_job.go with each guard broken in turn,
# injected with `go test -overlay`, so the source tree is never edited. Each mutant must be CONVICTED by a real
# `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='TestFootprintTransport'

out=$(go test -count=1 -run "$RUN_RE" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <source file> <python-regex pattern> <replacement>: exactly one substitution, or it is INERT
  local label="$1" src="$2" m ov out rc
  m=$(mktemp -p "$W" mut.XXXXXX) || exit 2
  ov=$(mktemp -p "$W" overlay.XXXXXX) || exit 2
  python3 - "$src" "$m" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re, sys
src, dst, pat, rep = sys.argv[1:5]
s = open(src).read()
n, c = re.subn(pat, lambda mt: mt.expand(rep), s, count=1)
if c != 1 or n == s: sys.exit(1)
open(dst, 'w').write(n)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  out=$(go test -count=1 -overlay "$ov" -run "$RUN_RE" -v . 2>&1); rc=$?
  score_mutant "$label" "$rc" "$out" || fails=$((fails+1))
}

mut "F1 addManifestChunks swallows a transport failure again" billing.go \
  '(func addManifestChunks\([^)]*\) \{\n\t)defer footprintSkip\(\)' '\1defer func() { recover() }()'
mut "F2 addRekeyProgress swallows a transport failure again" scope_rekey_job.go \
  '(\t\tfunc\(\) \{\n\t\t\t)defer footprintSkip\(\)(\n\t\t\tk, ok := unwrap\(kek, rec\.Next\))' '\1defer func() { recover() }()\2'
mut "F3 the legacy arm swallows a transport failure again" billing.go \
  'defer footprintSkip\(\)( // a bad/legacy manifest is skipped)' 'defer func() { recover() }()\1'
mut "F4 footprintSkip re-panics every value" billing.go \
  '(r := recover\(\)\n\t)if err, ok := r\.\(error\); ok && errors\.Is\(err, errStoreUnreachable\) \{' '\1if r != nil {'
mut "F5 installHeadroom's deferred recover removed" billing.go \
  '\tdefer func\(\) \{\n\t\tif r := recover\(\); r != nil \{\n\t\t\tfmt\.Fprintf\(os\.Stderr, "\[agent\] install headroom: [^\n]*\n[^\n]*\n[^\n]*\n\t\t\}\n\t\}\(\)\n' ''
[ "$fails" -eq 0 ] && echo "== all 5 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
