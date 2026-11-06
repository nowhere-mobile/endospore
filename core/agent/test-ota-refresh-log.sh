#!/usr/bin/env bash
# test-ota-refresh-log.sh [--mutate] -- runs ota_refresh_log_test.go (NWP-20261117-38): the OTA-REFRESH branch's
# `[ota] OTA-REFRESH forced` line, limited to one line per caller per hour, executed over a simulated day on a fake clock,
# plus `go vet ./...`. --mutate re-runs the tests with each guard broken in turn, restoring the files on exit: M1 the limiter
# bypassed inside line, M2 tap folded, M3 one window for all tags, M4 a free-form tag echoed, M5 the branch prints the
# line itself again, M6 the window on the monotonic clock. Each mutant must be CONVICTED by a real `--- FAIL` (one that
# does not apply, or does not compile, is a failure).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'if [ -f "$W/main.go.orig" ]; then mv -f "$W/main.go.orig" main.go; fi; if [ -f "$W/lim.go.orig" ]; then mv -f "$W/lim.go.orig" ota_refresh_log.go; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
MAIN=main.go
LIM=ota_refresh_log.go
RUN=(go test -count=1 -run 'TestOtaRefreshLog' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
out=$(go vet ./... 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; echo "go vet FAILED"; exit 1; fi
echo "go vet ./... ok"
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/main.go.orig"
cp "$LIM" "$W/lim.go.orig"
fails=0
mut() { # mut <label> <file> <regex pattern> <repl> [all] -- [all] replaces every match (at least one)
  local label="$1" file="$2" mout mrc
  python3 - "$file" "$3" "$4" "${5:-}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep,mode=sys.argv[1:5]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=0 if mode=='all' else 1,flags=re.S)
if c<1 or (mode!='all' and c!=1): sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$mout" || fails=$((fails+1))
  cp "$W/main.go.orig" "$MAIN"
  cp "$W/lim.go.orig" "$LIM"
}
mut "M1 the limiter bypassed inside line" "$LIM" '\t\tl\.folded\[tag\]\+\+\n\t\treturn "", false\n' ''
mut "M2 tap folded" "$LIM" '\tif tag == "tap" \{\n.*?\n\t\}\n' ''
mut "M3 one window for all tags" "$LIM" 'l\.(last|folded)\[tag\]' 'l.\g<1>["all"]' all
mut "M4 a free-form tag echoed" "$LIM" '\treturn "other"\n' '\treturn raw\n'
mut "M5 the branch prints the line itself" "$MAIN" 'otaRefreshLog\.note\(os\.Stderr, tag\)[^\n]*' 'fmt.Fprintf(os.Stderr, "[ota] OTA-REFRESH forced (caller=%s)\\n", tag)'
mut "M6 the window on the monotonic clock" "$LIM" 'now := l\.now\(\)\.Round\(0\)' 'now := l.now()'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
