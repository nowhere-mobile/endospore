#!/usr/bin/env bash
# test-build-warning-cache.sh [--mutate] -- runs build_warning_cache_test.go (NWP-20261113-27); --mutate re-runs it
# with the daemon's build-warning cache (build_warning_fetch.go) or its refresh call (main.go) broken in turn,
# restoring both files on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to
# compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap '[ -f "$W/fetch.orig" ] && cp -f "$W/fetch.orig" build_warning_fetch.go; [ -f "$W/main.orig" ] && cp -f "$W/main.orig" main.go; rm -rf "$W"' EXIT
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestBuildWarningCache|TestRefreshOtaCacheRefreshesBuildWarning' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp build_warning_fetch.go "$W/fetch.orig"
cp main.go "$W/main.orig"
cat >"$W/mut.py" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local res orig
  case "$2" in main.go) orig="$W/main.orig" ;; *) orig="$W/fetch.orig" ;; esac
  python3 "$W/mut.py" "$2" "$3" "$4" || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp -f "$orig" "$2"
}
mut "C1 an error keeps the previous warning instead of clearing it" build_warning_fetch.go \
  '(no notice: the fetch or the check failed"\)\n)\t\tw = nil\n\t\}' '\g<1>\t\treturn\n\t}'
mut "C2 the expiry check removed from buildWarningAffects" build_warning_fetch.go \
  'now < bwCurrent\.Expires && ' ''
mut "C3 the refreshBuildWarning call removed from refreshOtaCache" main.go \
  '\trefreshBuildWarning\(time\.Now\(\)\.Unix\(\), [^\n]*\n' ''
mut "C4 the call moved inside if latest != \"\" && avail {" main.go \
  '(\trefreshBuildWarning\(time\.Now\(\)\.Unix\(\), [^\n]*\n)(.*?\tif latest != "" && avail \{\n)' '\g<2>\t\g<1>'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
