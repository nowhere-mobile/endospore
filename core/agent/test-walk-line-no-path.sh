#!/usr/bin/env bash
# test-walk-line-no-path.sh [--mutate] -- NWP-20261102-03 (Q001 (e)): the seal walk's `[walk] unreadable` line and the
# `[seal] ... unreadable -> keeping` line carry a package or scope, the label and an error CODE, never a path. Runs the
# focused Go tests; --mutate applies each mutant to a pristine copy of incremental_seal.go (swapped in for the run,
# restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a
# failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp incremental_seal.go "$W/incremental_seal.go.orig" || exit 2
trap 'cp "$W/incremental_seal.go.orig" incremental_seal.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="SealBlind|SealWalk|WalkLine|ErrCode"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <old> <new>: replace the first <old> in a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" old="$2" new="$3" res
  cp "$W/incremental_seal.go.orig" incremental_seal.go
  if ! OLD="$old" NEW="$new" python3 -c "
import os
s = open('incremental_seal.go').read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open('incremental_seal.go','w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
mutate "W1 the pkg line prints the quoted path" \
  'unreadable pkg=%s ctx=%s err=%s\n", pkg, ctx,' 'unreadable %q ctx=%s err=%s\n", p, ctx,'
mutate "W1b the scope line prints the quoted path" \
  'unreadable scope=%s ctx=%s err=%s\n", blindScopeOf(p), ctx,' 'unreadable %q ctx=%s err=%s\n", p, ctx,'
mutate "W2 errCode passes err.Error() through" \
  'func errCode(err error) string {' $'func errCode(err error) string {\n\tif err != nil {\n\t\treturn err.Error()\n\t}'
mutate "W3 the [seal] line back to %v of the raw error" \
  'keeping the stored %s: %s\n", rel, kept, errCode(err))' 'keeping the stored %s: %v\n", rel, kept, err)'
mutate "W4 the scope prints the second path segment" \
  'return "other"' 'return strings.Split(p, "/")[2]'
cp "$W/incremental_seal.go.orig" incremental_seal.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
