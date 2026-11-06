#!/usr/bin/env bash
# test-media-user-share.sh [--mutate] -- runs media_user_share_test.go (NWP-20261119-18); --mutate re-runs it with
# media_user_share.go's Q106 classifier and main.go's #media-scoped share call broken in turn, restoring both files on
# exit. Each mutant must be CONVICTED by the named test's `--- FAIL`; one that fails to apply, or fails to compile,
# counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
SHARE=media_user_share.go
RUN=(go test -count=1 -run '^TestMediaUserShare' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$MAIN" "$W/main.go.orig"
cp "$SHARE" "$W/share.go.orig"
trap 'cp -f "$W/main.go.orig" "$MAIN" 2>/dev/null; cp -f "$W/share.go.orig" "$SHARE" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/main.go.orig" "$MAIN"; cp "$W/share.go.orig" "$SHARE"; }
# conv <label> <expected failing test>: run the suite against the mutated files, then restore them.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $2"* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
mut() { # mut <label> <file> <expected failing test> <python-regex pattern> <replacement>
  python3 - "$2" "$4" "$5" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1" "$3"
}
mut "M1 Download dropped from the Q106 set" "$SHARE" TestMediaUserShareClassifier \
  ', "Download"\}' '}'
mut "M2 a prefix match without the component boundary" "$SHARE" TestMediaUserShareClassifier \
  'first == d' 'strings.HasPrefix(rel, d) && first != ""'
mut "M3 Android/media classified other" "$SHARE" TestMediaUserShareClassifier \
  'return strings\.HasPrefix\(rel, q106AndroidMedia\)' 'return strings.HasPrefix(rel, "Android/media/x-never/")'
mut "M4 the share logged for every scope" "$MAIN" TestMediaUserShareRestoreCallsItOnceUnderTheMediaScope \
  'if isSharedMediaScope\(profile\) \{(\n\t+fmt\.Println\(mediaUserShareLine)' 'if true {\1'
mut "M5 the share call removed" "$MAIN" TestMediaUserShareRestoreCallsItOnceUnderTheMediaScope \
  '\n\t+if isSharedMediaScope\(profile\) \{\n\t+fmt\.Println\(mediaUserShareLine\(m\)\)\n\t+\}' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
