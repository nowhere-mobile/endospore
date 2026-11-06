#!/usr/bin/env bash
# test-media-log-paths.sh [--mutate] -- mediad's and the mid-session media sync's log lines print a session's media
# paths QUOTED (NWP-20261105-01, Q001 (e)), so log_scrub and the issue report's name rules take them. Plain: the four
# TestMedia*Path/Scrubbed tests. --mutate applies each mutant in place (a pristine copy lives in one temp root,
# restored after every mutant and on exit) and runs the same tests; each must be CONVICTED by the named `--- FAIL`.
# A mutant that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(mediafs.go media_server.go media_span.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
T='TestMediaLogLinesQuotePaths|TestMediaDamagedLineIsScrubbed|TestMediaFetchErrorQuotesItsPath|TestMediaSyncSkippedLineIsScrubbed'

out=$(go test -count=1 -run "$T" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want
  shift 4
  python3 - "$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(go test -count=1 -run "$T" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
mut "P1 the UNLINK line back to %s" mediafs.go 'dlog("mediad: UNLINK deferred %q (' 'dlog("mediad: UNLINK deferred %s (' TestMediaLogLinesQuotePaths
mut "P2 the media-sync SKIPPED line back to a bare rel" media_span.go $'fetchEssSpan(base, key, m, r)\n\t\tif err != nil {\n\t\t\tfmt.Printf("  media-sync: %q SKIPPED (%v)\\n", rel, errCode(err))' $'fetchEssSpan(base, key, m, r)\n\t\tif err != nil {\n\t\t\tfmt.Printf("  media-sync: %s SKIPPED (%v)\\n", rel, err)' TestMediaLogLinesQuotePaths TestMediaSyncSkippedLineIsScrubbed
mut "P3 markDamaged's line back to %s" media_server.go 'dlog("mediad: %q is CORRUPT' 'dlog("mediad: %s is CORRUPT' TestMediaLogLinesQuotePaths TestMediaDamagedLineIsScrubbed
mut "P4 the recreated-dir line back to %s" mediafs.go 'dlog("mediad: recreated missing deferred dir %q", target)' 'dlog("mediad: recreated missing deferred dir %s", target)' TestMediaLogLinesQuotePaths
mut "P5 fetchFile's damaged-chunk error back to a bare rel" media_server.go 'fmt.Errorf("mediad: %q: %w (not retrying)", rel, errDamagedChunk)' 'fmt.Errorf("mediad: %s: %w (not retrying)", rel, errDamagedChunk)' TestMediaLogLinesQuotePaths TestMediaFetchErrorQuotesItsPath
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
