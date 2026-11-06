#!/usr/bin/env bash
# test-ota-refresh.sh [--mutate] -- runs ota_refresh_test.go (refreshOtaCache and otaCheck EXECUTED) plus the source pins on
# refreshOtaCache (NWP-20261108-09); --mutate re-runs it against main.go with each guard broken in turn, restoring the
# file on exit. R1 the recovered wrapper removed, R2 the failure arm leaves otaLastTry unset, R3 a not-found recorded as
# "unreachable", R4 otaCheck's strict read back to getRef. NWP-20261120-05 adds ota_check_bound_test.go (the interim
# marker) and mutates ota_check_bound.go too: R5 the marker never started, R6 the marker's open-generation check removed,
# R7 the marker never ended, R8 the marker marks only once, R9 a refresh past its bound answers "checking", R10 "late"
# with every counter 0, R11 the outcome leaves the generation open. Each mutant must be CONVICTED by a real `--- FAIL`
# (one that does not apply, or does not compile, is a failure).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'for f in main.go ota_check_bound.go; do if [ -f "$W/$f.orig" ]; then mv -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
MAIN=main.go
BOUND=ota_check_bound.go
RUN=(go test -count=1 -run 'TestOtaRefresh|TestOtaInterim|TestRefreshOtaCacheRefreshesBuildWarning|TestOtaMandatoryIsWired|TestOtaNotesAreWired' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/$MAIN.orig"
cp "$BOUND" "$W/$BOUND.orig"
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local mout label="$1" file="$2"
  python3 - "$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp "$W/$file.orig" "$file"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$mout"; then echo "  convicted $label"
  elif [ -n "$(grep -E '\[build failed\]|^# ' <<<"$mout")" ]; then echo "  NOBUILD   $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp "$W/$file.orig" "$file"
}
mut "R1 the recovered wrapper removed" "$MAIN" 'err := recovered\(func\(\) \{ latest, avail = otaCheck\("s3", ""\) \}\)' 'latest, avail = otaCheck("s3", "")\n\tvar err error'
mut "R2 the failure arm leaves otaLastTry unset" "$MAIN" 'otaLastTry, otaLastErr = now, "unreachable"' 'otaLastErr = "unreachable"'
mut "R3 a not-found recorded as unreachable" "$MAIN" '(case latest == "":\n(?:\t\t//[^\n]*\n)*)\t\totaLastTry, otaLastErr = now, ""\n\t\totaCacheLatest, otaCacheAvail, otaCacheAt = "", false, now' '\g<1>\t\totaLastTry, otaLastErr = now, "unreachable"'
mut "R4 otaCheck reads the marker leniently" "$MAIN" 'b, _ := getRefBytesStrict\(base, otaVersionRef\(\)\)\n\tlatest = strings\.TrimSpace\(string\(b\)\)' 'latest = getRef(base, otaVersionRef())'
mut "R5 the marker never started" "$MAIN" '\n\tgoSafe\("ota-interim", func\(\) \{ otaInterimMark\(gen, done\) \}\)' ''
mut "R6 the marker's open-generation check removed" "$BOUND" '\t\tif otaRefreshOpen != gen \{\n\t\t\totaCacheMu\.Unlock\(\)\n\t\t\treturn\n\t\t\}\n' ''
mut "R7 the marker never ended" "$MAIN" '\n\tdefer close\(done\)' ''
mut "R8 the marker marks only once" "$BOUND" '(recorded unreachable while it keeps trying\\n", bound\)\n\t\t\}\n)' '\g<1>\t\treturn\n'
mut "R9 a refresh past its bound answers checking" "$MAIN" 'case refreshing && !late:' 'case refreshing && (late || !late):'
mut "R10 late with every counter 0" "$MAIN" 'late := otaInterimGen != 0 && otaInterimGen == otaRefreshOpen' 'late := otaInterimGen == otaRefreshOpen'
mut "R11 the outcome leaves the generation open" "$MAIN" '(if otaRefreshOpen == gen \{[^\n]*\n\t\t)otaRefreshOpen, otaInterimGen = 0, 0' '\g<1>otaInterimGen = 0'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
