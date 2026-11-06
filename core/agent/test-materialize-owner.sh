#!/usr/bin/env bash
# test-materialize-owner.sh [--mutate] -- NWP-20261102-17: a materialized media file takes its owner from the SCOPE
# ROOT, falling back to its own directory, best effort (writeMaterialized in media_span.go). The test that pins that
# order used to skip unless root, so CI never ran it. Plain: the test must PASS and must not SKIP. --mutate applies
# each mutant to a copy of this directory (the working tree is never touched); each must be CONVICTED by a `--- FAIL`.
# A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
T=TestMediaSync_OwnershipComesFromTheScopeRootNotTheParentDir

out=$(go test -count=1 -run "^$T\$" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
if [[ "$out" != *"--- PASS: $T"* ]]; then echo "FAILED: $T did not report PASS"; exit 1; fi
if [[ "$out" == *"--- SKIP"* ]]; then echo "FAILED: $T skipped; it must run on a non-root runner"; exit 1; fi
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent" || exit 2
cp "$W/agent/media_span.go" "$W/media_span.go.orig"
fails=0
# mut <label> <old-literal> <new-literal>
mut() {
  local label="$1" old="$2" new="$3" res
  cp -f "$W/media_span.go.orig" "$W/agent/media_span.go"
  if ! python3 - "$W/agent/media_span.go" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  res=$(cd "$W/agent" && go test -count=1 -run "^$T\$" -v . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $T"* ]]; then echo "  convicted $label"
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
}
t=$'\t'
mut "O1 the dir is consulted before the root" \
  "if root != \"\" {
${t}${t}${t}uid, gid, ok = materializeOwnerOf(root)
${t}${t}}
${t}${t}if !ok {
${t}${t}${t}uid, gid, ok = materializeOwnerOf(dir)
${t}${t}}" \
  "uid, gid, ok = materializeOwnerOf(dir)
${t}${t}if !ok && root != \"\" {
${t}${t}${t}uid, gid, ok = materializeOwnerOf(root)
${t}${t}}"
mut "O2 the dir fallback removed" \
  "
${t}${t}if !ok {
${t}${t}${t}uid, gid, ok = materializeOwnerOf(dir)
${t}${t}}" ""
mut "O3 the chown error returned" \
  "_ = materializeChown(tmpName, uid, gid)" \
  "if err := materializeChown(tmpName, uid, gid); err != nil {
${t}${t}${t}return err
${t}${t}}"
mut "O4 the root != \"\" guard removed" \
  "if root != \"\" {
${t}${t}${t}uid, gid, ok = materializeOwnerOf(root)" \
  "if true {
${t}${t}${t}uid, gid, ok = materializeOwnerOf(root)"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
