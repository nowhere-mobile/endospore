#!/usr/bin/env bash
# test-index-conditional.sh [--mutate] -- runs the TestIndexConditional_* and TestRefreshIndex_* tests
# (NWP-20261102-11); --mutate re-runs them against index.go with each part of the conditional GET broken in turn,
# restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
IDX=index.go
trap '[ -f "$W/$IDX.orig" ] && cp -f "$W/$IDX.orig" "$IDX"; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'RefreshIndex|IndexConditional' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$IDX" "$W/$IDX.orig"
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local res rc
  python3 - "$IDX" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  if [ $rc -ne 0 ] && grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"
  elif grep -q -E 'build failed|\[setup failed\]' <<<"$res"; then echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1 (rc=$rc, no --- FAIL)"; fails=$((fails+1)); fi
  cp -f "$W/$IDX.orig" "$IDX"
}
mut "I1 no If-Modified-Since header" 'req\.Header\.Set\("If-Modified-Since", since\.UTC\(\)\.Format\(http\.TimeFormat\)\)' '_ = since'
mut "I2 304 treated as an error" 'if resp\.StatusCode == http\.StatusNotModified && !since\.IsZero\(\) \{' 'if false && resp.StatusCode == http.StatusNotModified && !since.IsZero() {'
mut "I3 .sig still fetched on 304" 'if notModified \{' 'if false && notModified {'
mut "I4 mtime not set from Last-Modified" 'if !lastMod\.IsZero\(\) \{' 'if false && !lastMod.IsZero() {'
[ "$fails" -eq 0 ] || { echo "== $fails mutant(s) not convicted"; exit 1; }
echo "== all mutants convicted"
