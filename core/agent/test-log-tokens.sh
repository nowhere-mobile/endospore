#!/usr/bin/env bash
# test-log-tokens.sh [--mutate] -- runs logtoken_test.go and the egress-line pins (NWP-20261116-24): a daemon verdict
# prints in brackets with no double quote (logVal), a platform interface prints bare and any other quoted (ifaceTok), and
# GRANT-PERMS hands roamd the session's profile name. --mutate re-runs them with each piece broken in turn, restoring
# every file on exit. Each mutant must be CONVICTED (a `--- FAIL` line); one that fails to apply or to compile counts as
# a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(logtoken.go logoff_cutoff.go main.go)
restore_all() {
  local f
  for f in "${FILES[@]}"; do
    [ -f "$W/$f" ] && cp "$W/$f" "$f"
  done
  return 0
}
trap 'restore_all; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestLogVal|TestIfaceTok|TestEgressLine|TestLogoffCutoffLine|TestGrantPermsName' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f" || exit 2; done
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label="$1" file="$2" res mrc
  python3 - "$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  restore_all
}
mut 'T1 logVal keeps "' logtoken.go "c == '\"' \\|\\| " ''
mut "T2 logVal prints an empty value without its - placeholder" logtoken.go 'return "\[-\]"' 'return "[]"'
mut "T3 ifaceTok prints every interface bare" logtoken.go 'if sysIfaceRe\.MatchString\(s\) \{' 'if true {'
mut "T4 the cutoff line back on %q" logoff_cutoff.go 'cutoff %s in %dms(.*?)uid, logVal\(r\), ' 'cutoff %q in %dms\1uid, r, '
mut "T5 GRANT-PERMS back on the uid in the name slot" main.go 'triggerRoamWorker\(dest, "grant", grantNameArg\(dest, uid\), ' 'triggerRoamWorker(dest, "grant", uid, '
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
