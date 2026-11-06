#!/usr/bin/env bash
# test-logout-wallet.sh [--mutate] -- runs logout_wallet_test.go (NWP-20261017-02); --mutate re-runs it against
# logout_wallet.go / wallet_lock.go / main.go with each guard broken in turn, restoring the files on exit. Each
# mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
LW=logout_wallet.go; WL=wallet_lock.go; MAIN=main.go
RUN=(go test -count=1 -run 'TestLogoutWallet_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -15
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

for f in "$LW" "$WL" "$MAIN"; do cp "$f" "$f.orig"; done
trap 'for f in "$LW" "$WL" "$MAIN"; do mv -f "$f.orig" "$f"; done' EXIT
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  local res mrc
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$1" "$mrc" "$res" || fails=$((fails+1))
  for f in "$LW" "$WL" "$MAIN"; do cp "$f.orig" "$f"; done
}
mut "M1 publish from the file, not the copy" "$LW" 'sealWalletValueDurable\("s3", name, pass, dk, wp, &w, basis, gen, proven\)' 'sealWalletDurable("s3", name, pass, dk, wp)'
mut "M2 bytes check removed" "$WL" '\|\| !bytes\.Equal\(cur, basis\)' '|| (false && !bytes.Equal(cur, basis))'
mut "M3 generation check removed from the drop" "$WL" 'if !walletAtGeneration\(walletPath, gen\) \{\n\t\treturn false, "the wallet changed hands"' 'if false && !walletAtGeneration(walletPath, gen) {
		return false, "the wallet changed hands"'
mut "M4 file removed on a publish error" "$LW" 'if err != nil \{\n(\t\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] logout wallet user %s: NOT)' 'if err != nil {
			os.Remove(wp)
			fmt.Fprintf(os.Stderr, "[logind] logout wallet user %s: NOT'
mut "M5a call removed" "$MAIN" '\t\tgoSafe\("logout-wallet", func\(\) \{\n\t\t\tlogoutRenewStep[^\n]*\n.*?\n\t\t\}\)\n' ''
cp "$MAIN" "$MAIN.m5"
python3 - "$MAIN" <<'PY' || { echo "  INERT     M5b -- the failed-arm insertion did not apply"; fails=$((fails+1)); }
import sys
p=sys.argv[1]; s=open(p).read()
a='\t\tgoSafe("logout-wallet", func() {\n\t\t\tlogoutRenewStep(dest, name, pass, seFromHex(seSecret), lgen, uid)\n\t\t\tlogoutWalletStep(dest, name, pass, seFromHex(seSecret), lgen, uid)\n\t\t\tforgetSessionKeys("sign-out wallet published")\n\t\t})\n'
k='\t\t\tfmt.Fprintf(os.Stderr, "[logind] logout seal %q user %s FAILED (%s) -> staying signed in, NOT reaping\\n"'
assert s.count(a)==1 and s.count(k)==1
s=s.replace(a,'').replace(k,a+k)
open(p,'w').write(s)
PY
res=$("${RUN[@]}" 2>&1); mrc=$?
score_mutant "M5b call moved into the failed arm" "$mrc" "$res" || fails=$((fails+1))
for f in "$LW" "$WL" "$MAIN"; do cp "$f.orig" "$f"; done; rm -f "$MAIN.m5"
mut "M6 proven check removed" "$LW" 'if !proven \{\n\t\treturn false, errWalletNotRestored\n\t\}' 'proven = true'
mut "M7 removal outcome ignored" "$WL" 'if len\(left\) > 0 \{' 'if false && len(left) > 0 {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
