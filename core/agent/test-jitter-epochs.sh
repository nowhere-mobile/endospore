#!/usr/bin/env bash
# test-jitter-epochs.sh [--mutate] -- runs jitter_epochs_test.go (NWP-20261020-27); --mutate re-runs it against
# billing.go with each rule broken in turn, restoring the file on exit. Each mutant must be CONVICTED (a real
# --- FAIL; one that fails to apply or to compile counts as a failure).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
F=billing.go
RUN=(go test -count=1 -run 'TestJitterEpochs_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$F.orig"
trap 'mv -f "$F.orig" "$F"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  python3 - "$F" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  if [ $rc -ne 0 ] && grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1 (rc=$rc, no --- FAIL)"; fails=$((fails+1)); fi
  cp "$F.orig" "$F"
}
mut "one-byte modulo restored" 'v, err := rand\.Int\(jitterRand, new\(big\.Int\)\.Add\(big\.NewInt\(n\), big\.NewInt\(1\)\)\)\n\tif err != nil \{\n\t\treturn onErr\n\t\}\n\treturn v\.Int64\(\)' '_ = big.NewInt
	var b [1]byte
	if _, err := io.ReadFull(jitterRand, b[:]); err != nil {
		return onErr
	}
	return int64(b[0]) % (n + 1)'
mut "negative override clamped to 0" 'n >= 0 \{' 'true {
			if n < 0 {
				return 0
			}'
mut "error path returns 0" 'return onErr' 'return 0'
mut "default bound off by one" 'return drawJitter\(activationJitterEpochs, activationJitterEpochs\)' 'return drawJitter(activationJitterEpochs-1, activationJitterEpochs)'
mut "bound computed as big.NewInt(n+1)" 'new\(big\.Int\)\.Add\(big\.NewInt\(n\), big\.NewInt\(1\)\)' 'big.NewInt(n+1)'
[ $fails -eq 0 ] || { echo "$fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
