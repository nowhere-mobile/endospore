#!/usr/bin/env bash
# test-relogin-headcheck.sh [--mutate] -- runs the RELOGIN head-check tests (NWP-20261103-02): a stored head takes the
# relogin path, a definitely absent one keeps the session as a throwaway (NOSTORED), a failed read keeps everything
# (ERR-STORE). --mutate re-runs them against main.go with the check removed, loosened, or its NOSTORED arm broken,
# restoring the file on exit. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to
# compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
SRC=main.go
W=$(mktemp -d -t r.XXXXXX) || exit 2
trap 'cp -f "$W/main.go.orig" "$SRC" 2>/dev/null; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'Relogin' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/main.go.orig"
fails=0
restore() { cp "$W/main.go.orig" "$SRC"; }
# conv <label>: run the suite against the mutated file, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *'--- FAIL: Test'* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
# mut <label> <python-regex pattern> <replacement>: exactly one match, or INERT.
mut() {
  python3 - "$SRC" "$2" "$3" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1"
}
mut "R1 the check removed (always stored)" 'return head != "", nil' $'return head != "" || true, nil'
mut "R2 a failed read is taken for absence" 'stored, err := reloginStoredHead\(reloginStoreBase, name, pass\)\n\tif err != nil \{' $'stored, err := reloginStoredHead(reloginStoreBase, name, pass)\n\tif err != nil {\n\t\tstored, err = false, nil\n\t}\n\tif err != nil {'
mut "R3 NOSTORED still runs the logoff" 'NOSTORED, session kept as a throwaway\\n", name\)\n\t\tfmt.Fprint\(conn, "NOSTORED\\n"\)' $'NOSTORED, session kept as a throwaway\\n", name)\n\t\thandleLogout(conn, dest)\n\t\tfmt.Fprint(conn, "NOSTORED\\n")'
mut "R4 NOSTORED leaves .offlinesession" 'if !stored \{\n\t\tclearOfflineSession\(dest\)' $'if !stored {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
