#!/usr/bin/env bash
# test-discovery-bound.sh [--mutate] -- runs the bounded-discovery-lookup tests (NWP-20261109-16); --mutate re-runs them
# against main.go with each bound removed in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
SRC=main.go
trap '[ -f "$W/$SRC" ] && cp -f "$W/$SRC" "$SRC"; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='TestDiscoBound|TestDiscoAnonLookup'

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
if xf == 'bareget':
    s = once('(&http.Client{Timeout: discoTimeout}).Get(discoURL(key))', 'http.Get(discoURL(key))', s)
elif xf == 'anoncap':
    s = once('io.ReadAll(io.LimitReader(resp.Body, discoMaxBody+1))', 'io.ReadAll(resp.Body)', s)
elif xf == 'key403':
    s = once('fmt.Fprintln(os.Stderr, "[disco] anon GET -> 403 (is the discovery bucket public-read?)")',
             'fmt.Fprintf(os.Stderr, "[disco] anon GET %s -> 403 (is the discovery bucket public-read?)\\n", key)', s)
elif xf == 'keyedctx':
    s = once('ctx, cancel := context.WithTimeout(context.Background(), discoTimeout)\n\tdefer cancel()\n\tobj, err := discoClient.GetObject(ctx,',
             'obj, err := discoClient.GetObject(context.Background(),', s)
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
mut "M1 discoGetAnon back to bare http.Get" bareget TestDiscoBoundAnonStallIsAMiss
mut "M2 anonymous LimitReader dropped" anoncap TestDiscoBoundEndlessAnswerStopsAtTheCap
mut "M3 the key back in the 403 line" key403 TestDiscoBound403LogsNoRef
mut "M4 discoGet back to context.Background()" keyedctx TestDiscoBoundKeyedStallReturns
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
