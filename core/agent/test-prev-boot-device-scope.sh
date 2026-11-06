#!/usr/bin/env bash
# test-prev-boot-device-scope.sh [--mutate] -- runs prev_boot_device_scope_test.go (NWP-20261126-15, dn-1105 #1 for the
# previous boot's kernel tail); --mutate re-runs it against a PACKAGE COPY per mutant with one rule of
# deviceScopePrevBoot or its call broken in turn. Each mutant must be CONVICTED (a `--- FAIL`); one that fails to
# apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestPrevBootDeviceScope' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local d res
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R ./*.go go.mod go.sum blindrsa testdata third_party "$d"/
  if ! python3 - "$d/report_issue.go" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; fi
  res=$(cd "$d" && "${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  rm -rf "$d"
}
mut "M1 the device-scope call removed" 'pb = deviceScopePrevBoot\(pb\)' '_ = deviceScopePrevBoot'
mut "M2 a denial kept as is" 'kept = append\(kept, deviceScopeDenials\(\[\]string\{ln\}\)\.\.\.\)' 'kept = append(kept, ln)'
mut "M3 the avc test dropped" '(func deviceScopePrevBoot\(lines \[\]string\) \[\]string \{.*?)if strings\.Contains\(ln, "avc:"\) && strings\.Contains\(ln, "denied"\) \{' '\1if true {'
mut "M4 the call made at every scope" 'if deviceScope \{\n\t\tpb = deviceScopePrevBoot' 'if true {
		pb = deviceScopePrevBoot'
mut "M5 the header line dropped" '(func deviceScopePrevBoot\(lines \[\]string\) \[\]string \{\n.*?)for _, ln := range lines \{' '\1for _, ln := range lines {
		if strings.HasPrefix(ln, "--- ") {
			continue
		}'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
