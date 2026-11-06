#!/usr/bin/env bash
# test-torn-deferred.sh [--mutate] -- runs TestTornDeferred* in torn_deferred_test.go (NWP-20261024-01): a deferred
# file that tears during the seal's read leaves none of its raw bytes in the essential tar stream. --mutate re-runs
# them against incremental_seal.go / main.go with each guard broken in turn, restoring the files on exit (the pristine
# copies live in one scratch root, never beside the sources). Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
SEAL=incremental_seal.go; MAIN=main.go
trap 'for f in "$SEAL" "$MAIN"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
RUN=(go test -count=1 -timeout 300s -run 'TestTornDeferred' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "$SEAL" "$MAIN"; do cp "$f" "$W/$f.orig"; done
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local res f
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  for f in "$SEAL" "$MAIN"; do cp "$W/$f.orig" "$f"; done
}
mut "D1 the torn branch appends no discard range" "$SEAL" 'discard = append\(discard, scanRange\{rel: rel, start: start, end: end \+ 1\}\)' '_ = discard'
mut "D2 pushProfile ignores discard" "$MAIN" 'range sealDiscard \{' 'range sealDiscard[:0] {'
mut "D3 the discard range stops one chunk short" "$SEAL" 'scanRange\{rel: rel, start: start, end: end \+ 1\}\)\n\t\t\t\t\t\}\n\t\t\t\t\tseen' 'scanRange{rel: rel, start: start, end: end})
					}
					seen'
mut "D4 pushProfile builds a Deferred entry from a discard range" "$MAIN" '\n\tvar deferredMap map' '
	deferredR = append(deferredR, sealDiscard...)
	var deferredMap map'
mut "D5 the discard marking moves inside the deferred-record block" "$MAIN" 'range sealDiscard \{' 'range func() []scanRange {
		if len(deferredR) > 0 || len(carriedDef) > 0 {
			return sealDiscard
		}
		return nil
	}() {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
