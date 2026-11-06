#!/usr/bin/env bash
# test-resolver-plain-err.sh [--mutate] -- runs resolver_plain_err_test.go (NWP-20261014-49); --mutate re-runs it
# against resolver.go with the joined dial error broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED; one that fails to apply counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
F=resolver.go
RUN=(go test -count=1 -run 'TestDialPlain_|TestDescribeDialErr_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$F.orig"
trap 'mv -f "$F.orig" "$F"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl>
  python3 - "$F" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  if "${RUN[@]}" >/dev/null 2>&1; then echo "  SURVIVED  $1"; fails=$((fails+1)); else echo "  convicted $1"; fi
  cp "$F.orig" "$F"
}
mut "M1 Error() keeps only the last part" 'strings\.Join\(parts, "; "\)' 'parts[len(parts)-1]'
mut "M2 parts joined without the separator" 'strings\.Join\(parts, "; "\)' 'strings.Join(parts, " ")'
mut "M3 the first server is not recorded" 'pe\.addrs = append\(pe\.addrs, a\)\n\t\tpe\.errs = append\(pe\.errs, e\)' 'pe.addrs = append(pe.addrs[:0], a)
		pe.errs = append(pe.errs[:0], e)'
mut "M4 kinds() names the address" 'out\[i\] = describeDialErr\(err\)' 'out[i] = e.addrs[i] + ": " + describeDialErr(err)'
mut "M5 an empty list returns the joined error" 'len\(pe\.errs\) == 0 \{\n\t\treturn nil, errors\.New\("resolver: no dns servers configured"\)' 'len(pe.errs) == 0 {
		return nil, pe'
mut "M6 describeDialErr drops the AddrError arm" '\tvar ae \*net\.AddrError\n\tif errors\.As\(err, &ae\) \{.*?\n\t\}\n\tif errors\.As\(err, &oe\)' '\tif errors.As(err, &oe)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
