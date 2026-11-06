#!/usr/bin/env bash
# test-seal-stop.sh [--mutate] -- runs the TestSealStop tests in seal_stop_test.go (NWP-20261117-01, h47 #1 part 1):
# a push run with NOWHERE_SEAL_STOPPABLE=1 stops at its next chunk boundary when $NOWHERE_STATE/.sealstop exists --
# in the walk, before the /quote, before the lease, before each blob PUT -- publishes no head and exits 7, and a stop
# raised once the pointer pass has begun is ignored. A push without the variable ignores the file.
# --mutate re-runs them against main.go and seal_stop.go with each rule broken in turn, restoring both files on exit
# (the pristine copies live in one scratch root, never beside the source). Each mutant must be CONVICTED by a real
# `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
trap 'for f in main.go seal_stop.go; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestSealStop' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp seal_stop.go "$W/seal_stop.go.orig"
fails=0
mut() { # mut <label> <file> <regex pattern> <repl, with \1-style group references> [count, default 1]
  local label="$1" f="$2" res
  python3 - "$f" "$3" "$4" "${5:-1}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep,want=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,flags=re.S)
if c!=want: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $label"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp "$W/$f.orig" "$f"
}
mut "S1 sealStopAsked ignores sealStoppable" seal_stop.go \
  '\tif !sealStoppable \{\n\t\treturn false\n\t\}\n' ''
mut "S2 no walk-phase check" main.go \
  '\t\tif sealStopNow\(\) \{\n\t\t\tpanic\(sealStopSignal\{\}\)[^\n]*\n\t\t\}\n' '' 2
mut "S3 no pre-lease check" main.go \
  '\tif sealStopNow\(\) \{\n\t\treturn // h47 #1: a stop was requested before the lease[^\n]*\n\t\}\n' ''
mut "S4 no check in uploadBlobs' serial loop" main.go \
  '(for _, b := range work \{\n)\t\t\tif sealStopNow\(\) \{\n\t\t\t\treturn\n\t\t\t\}\n(\t\t\tupload1\(b, &rbuf\))' '\1\2'
mut "S5 the stop honoured inside the pointer pass" main.go \
  '(\tfor _, k := range order \{\n)(\t\tv := st\.refs\[k\]\n\t\tif len\(v\) == 0 \{\n\t\t\tcontinue // a tombstone)' '\1\t\tif sealStopNow() {\n\t\t\treturn\n\t\t}\n\2'
mut "S6 push exits 0 on a stop" main.go \
  'os\.Exit\(exitSealStopped\)' '_ = exitSealStopped'
mut "S7 push stoppable without NOWHERE_SEAL_STOPPABLE" main.go \
  'sealStoppable = os\.Getenv\("NOWHERE_SEAL_STOPPABLE"\) == "1"' 'sealStoppable = true'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
