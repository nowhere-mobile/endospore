#!/usr/bin/env bash
# test-footprint-refused.sh [--mutate] -- runs footprint_refused_test.go (NWP-20261118-02, h48 #10): a scope head the
# store refuses (403, even on a fresh cap) raises errStoreUnreachable on cap mode and on plain HTTP, GET-USAGE's line,
# payRent and the export index fail closed, installHeadroom fails open, and a scope with no head stays measured.
# --mutate re-runs the cases against a copy of billing.go with each guard broken in turn, injected with
# `go test -overlay`, so the source tree is never edited. Each mutant must be CONVICTED by a real `--- FAIL`; one
# that does not apply, does not compile, or dies without a FAIL line counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='TestFootprintRefused'

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

mut "M1 the head is read with headKey + getRef again" billing.go \
  'hk, head := footprintHeadStrict\(base, scope, pass\)' 'hk := headKey(base, scope, pass); head := getRef(base, hk)'
mut "M2 the helper re-panics a plain failure unmarked" billing.go \
  'panic\(storeReadErr\{fmt\.Errorf\("footprint: head of a scope refused: %v", r\)\}\)' 'panic(r)'
mut "M3 the walk uses the non-strict probe" billing.go \
  'headRefWith\(base, scope, pass, refProbeStrict\)' 'headRefWith(base, scope, pass, refProbe)'
[ "$fails" -eq 0 ] && echo "== all 3 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
