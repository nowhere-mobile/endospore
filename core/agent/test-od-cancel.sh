#!/usr/bin/env bash
# test-od-cancel.sh [--mutate] -- runs the MATERIALIZE-APP sign-out cancel tests (NWP-20261109-11, Q116); --mutate
# re-runs them against app_code.go with the cancel broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
SRC=app_code.go
trap '[ -f "$W/$SRC" ] && cp -f "$W/$SRC" "$SRC"; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='OdCancel'

out=$(go test -count=1 -run "$RUN_RE" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/$SRC"
fails=0
mut() { # mut <label> <transform> <convicting test>...
  local label="$1" xf="$2" res want miss=""
  shift 2
  python3 - "$SRC" "$xf" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$SRC" "$SRC"; return; }
import sys
p, xf = sys.argv[1:3]
s = open(p).read()
def once(a, b, text):
    if text.count(a) != 1:
        sys.exit(1)
    return text.replace(a, b)
if xf == 'nowrite':
    s = once('if w.cancelled != nil && w.cancelled() {', 'if false {', s)
elif xf == 'noprecheck':
    s = once('\tif odCancelRequested() { // Q116', '\tif false { // Q116', s)
elif xf == 'noenv':
    s = once('p := os.Getenv("NOWHERE_OD_CANCEL")', 'p := ""', s)
elif xf == 'plain':
    s = once('\t\treturn errMaterializeCancelled\n', '\t\treturn errors.New("stopped")\n', s)
else:
    sys.exit(1)
open(p, 'w').write(s)
PY
  res=$(go test -count=1 -run "$RUN_RE" -v . 2>&1)
  if [[ "$res" == *"[build failed]"* ]]; then
    echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      [[ "$res" == *"--- FAIL: $want"* ]] || miss="$miss $want"
    done
    if [ -z "$miss" ]; then echo "  convicted $label"
    else echo "  SURVIVED  $label -- not failed by:$miss"; fails=$((fails+1)); fi
  fi
  cp -f "$W/$SRC" "$SRC"
}
mut "N1 write() never consults cancelled" nowrite TestOdCancelStopsBetweenChunks
mut "N2 the pre-fetch check removed" noprecheck TestOdCancelBeforeTheFirstFetch
mut "N3 odCancelRequested ignores the env var" noenv TestOdCancelStopsBetweenChunks TestOdCancelBeforeTheFirstFetch
mut "N4 the cancel does not wrap errMaterializeCancelled" plain TestOdCancelStopsBetweenChunks
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
