#!/usr/bin/env bash
# test-receipt-after-flush.sh [--mutate] -- runs the TestReceiptAfterFlush tests in receipt_after_flush_test.go
# (NWP-20261123-01): in cap mode the receipt moves only after its head's PUT has landed. A failed blob PUT, a failed
# head PUT and a head the publish pass refuses leave the receipt unchanged, and the next seal logs no STALE BASE; a
# head PUT the store applied whose answer was lost is settled by one read; capAbort drops the waiting work; a clean
# cap-mode or direct push still moves the receipt, and a session with no receipt still gets none.
# --mutate re-runs them against main.go and cap_after_publish.go with each rule broken in turn, restoring both files
# on exit (the pristine copies live in one scratch root, never beside the source). Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
FILES=(main.go cap_after_publish.go)
trap 'for f in "${FILES[@]}"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestReceiptAfterFlush' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <regex pattern> <repl, with \1-style group references>
  local label="$1" file="$2" res mrc
  python3 - "$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  cp "$W/$file.orig" "$file"
}
mut "M1 putHeadGuarded re-anchors the receipt at the buffer again" main.go \
  'capAfterPublish\(profileRefV2\(name, passphrase\), func\(\) \{ reanchorReceipt\(name, passphrase, val\) \}\)' \
  'reanchorReceipt(name, passphrase, val)'
mut "M2 the publish pass runs a key's hooks before its PUT" main.go \
  'if put\(k, v\) \{\n\t+st\.runAfterPublish\(k, v\)\n\t+\}' \
  'st.runAfterPublish(k, v)\nput(k, v)'
mut "M3 a key the stale check skips runs its hooks" main.go \
  '(if stalePublish\("s3", k, "cap-flush"\) \{\n)' \
  '\1st.runAfterPublish(k, v)\n'
mut "M4 the lost response is not read back" cap_after_publish.go \
  '(func capPointerLanded\(key string, want \[\]byte\) bool \{\n)' \
  '\1if len(want) >= 0 {\nreturn false\n}\n'
mut "M5 a read-back that differs counts as landed" cap_after_publish.go \
  '&& bytes\.Equal\(got, want\)' \
  '&& got != nil'
mut "M6 the hooks run at bracket end whatever happened" main.go \
  '(defer st\.spill\.Close\(\)\n)' \
  '\1defer func() {\nfor k, v := range st.refs {\nst.runAfterPublish(k, v)\n}\n}()\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
