#!/usr/bin/env bash
# test-torn-grouped.sh [--mutate] -- runs TestTornGrouped* (torn_grouped_test.go, NWP-20261027-06): a grouped small
# file that changes while the seal reads it is read whole, checked by a post-read fstat, and read once more. --mutate
# re-runs them against incremental_seal.go with each guard broken in turn, restoring the file on exit (the pristine
# copy lives in one scratch root, never beside the source). Each mutant must be CONVICTED by a real `--- FAIL`; one
# that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
export TMPDIR="$W" GOTMPDIR="$W"
SEAL=incremental_seal.go
trap '[ -f "$W/$SEAL.orig" ] && cp -f "$W/$SEAL.orig" "$SEAL"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -timeout 300s -run 'TestTornGrouped|TestTornEssential|TestSealTarHeader' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SEAL" "$W/$SEAL.orig"
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local res
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
  cp "$W/$SEAL.orig" "$SEAL"
}
mut "G1 writeEntriesTar calls writeTarEntry again" "$SEAL" 'writeGroupedEntryChecked\(tw, e.path, e.info, e.rel\)\n' 'writeTarEntryChecked(tw, e.path, e.info, e.rel)
'
mut "G2 the post-read whole-check is always true" "$SEAL" 'whole := int64\(len\(buf\)\) == info.Size\(\)[^\n]*\n' 'whole := true
'
mut "G3 the second read is removed" "$SEAL" 'buf, fi, ok, err = read\(\)\n' 'ok, err = true, nil
'
mut "G4 the second read loops until whole" "$SEAL" 'buf, fi, ok, err = read\(\)\n' 'buf, fi, ok, err = read()
		for ok && err == nil && (int64(len(buf)) != fi.Size() || !fi.ModTime().Equal(first.ModTime())) {
			first = fi
			if _, err = f.Seek(0, io.SeekStart); err != nil {
				return false, err
			}
			buf, fi, ok, err = read()
		}
'
mut "G5 the torn header keeps the walk-time size" "$SEAL" 'hdr.Size = int64\(len\(buf\)\)\n' 'hdr.Size = info.Size()
'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
