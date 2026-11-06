#!/usr/bin/env bash
# test-torn-essential.sh [--mutate] -- runs TestTornEssential* in torn_essential_test.go (NWP-20261024-03): a
# file-aligned ESSENTIAL file that changes while the seal copies it is discarded and read once more. --mutate re-runs
# them against incremental_seal.go with each guard broken in turn, restoring the file on exit (the pristine copy
# lives in one scratch root, never beside the source). Each mutant must be CONVICTED by a real `--- FAIL`; one that
# fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
SEAL=incremental_seal.go
trap '[ -f "$W/$SEAL.orig" ] && cp -f "$W/$SEAL.orig" "$SEAL"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -timeout 300s -run 'TestTornEssential' -v .)

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
mut "E1 no tear detection" "$SEAL" 'torn = n < hdr.Size\n\tif fi, ferr := f.Stat\(\); ferr == nil && \(fi.Size\(\) != hdr.Size \|\| !fi.ModTime\(\).Equal\(info.ModTime\(\)\)\) \{\n\t\ttorn = true\n\t\}' 'torn = false'
mut "E2 a tear discards but is not read again" "$SEAL" 'start, end, torn, werr = read\(fi\)' 'start, end, torn, werr = -1, -1, false, nil'
mut "E3 the re-read reuses the walk-time info" "$SEAL" 'start, end, torn, werr = read\(fi\)' 'start, end, torn, werr = read(info)'
mut "E4 the re-read loops until a read is not torn" "$SEAL" 'start, end, torn, werr = read\(fi\)\n' 'start, end, torn, werr = read(fi)
						for torn && werr == nil && start >= 0 {
							if fi, lerr := os.Lstat(p); lerr == nil {
								start, end, torn, werr = read(fi)
								recMt, recSz, recMd = fi.ModTime().UnixNano(), fi.Size(), uint32(fi.Mode())
							}
						}
'
mut "E5 the first read is not appended to discard" "$SEAL" 'discard = append\(discard, scanRange\{rel: rel, start: start, end: end \+ 1\}\)\n\t\t\t\t\tfmt.Fprintf\(os.Stderr, "\[seal\] %q changed while it was read -> reading' '_ = discard
					fmt.Fprintf(os.Stderr, "[seal] %q changed while it was read -> reading'
mut "E6 the goroutine passes the tear to CloseWithError" "$SEAL" 'pw.CloseWithError\(e\)\n\t\t\t\t\t\tdone' 'if tn {
							e = errors.New("torn")
						}
						pw.CloseWithError(e)
						done'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
