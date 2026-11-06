#!/usr/bin/env bash
# test-resolver-seed-iface.sh [--mutate] -- runs resolver_seed_iface_test.go and the cache/seed tests
# (NWP-20261119-25); --mutate re-runs them against resolver.go with the any-age seed or its interface key broken in
# turn, restoring the file on exit. Each mutant must be CONVICTED with a --- FAIL; one that does not apply or does
# not compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
F=resolver.go
RUN=(go test -count=1 -run 'TestResolverSeed_|TestDNSCache|TestDoTSeedKeepsPostureWhenServersAged' .)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/orig"
trap 'cp -f "$W/orig" "$F"; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local o r
  python3 - "$F" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
  o=$("${RUN[@]}" 2>&1); r=$?
  score_mutant "$1" "$r" "$o" || fails=$((fails+1))
  cp -f "$W/orig" "$F"
}
mut "M1 the age gate is back" 'if !ok \{\n\t\treturn // absent -- start cold' 'if !ok || age > dnsKeepMax {
		return // absent -- start cold'
mut "M2 the seed-interface key is removed" 'case dnsSeedIface != "" && iface != "" && iface != dnsSeedIface:' 'case false:'
mut "M3 dnsSeedIface is never cleared" '\n\t\tdnsSeedIface = ""\n' '
'
mut "M4 the iface line is not written" 'if validCacheIface\(iface\) \{' 'if false {'
mut "M5 saveDoTCache drops the iface line" 'writeDNSCache\(st, addrs, host, ips, time\.Now\(\)\.Add\(-age\), iface\)' 'writeDNSCache(st, addrs, host, ips, time.Now().Add(-age), iface[:0])'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
