#!/usr/bin/env bash
# test-report-siblings.sh [--mutate] -- runs report_siblings_test.go (NWP-20261204-20, backlog: Four sibling Wi-Fi/network
# stores nothing sweeps): every issue report, the gate's included, carries the boot sweep's siblings line as the status
# key bootsweep_siblings, fixed tokens only. --mutate re-runs it against report_siblings.go and report_issue.go with each
# rule broken in turn, restoring both on exit. Each mutant must be CONVICTED (a `--- FAIL`); one that fails to apply or
# to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export GOTMPDIR="$W"
RUN=(go test -count=1 -run 'BootsweepSiblings' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp report_siblings.go "$W/report_siblings.go.orig"
cp report_issue.go "$W/report_issue.go.orig"
trap 'cp -f "$W/report_siblings.go.orig" report_siblings.go; cp -f "$W/report_issue.go.orig" report_issue.go; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label=$1 file=$2 res
  python3 - "$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp "$W/$file.orig" "$file"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $label"; else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp "$W/$file.orig" "$file"
}
mut "M1 first matching line wins (T1 _LastRoamdLineWins)" report_siblings.go \
  'if strings\.HasPrefix\(ln, bootsweepSiblingsPrefix\) \{' 'if strings.HasPrefix(ln, bootsweepSiblingsPrefix) && last == "" {'
mut "M2 value regex loosened to ^\\S+\$ (T2 _ValueShapes)" report_siblings.go \
  'regexp\.MustCompile\(`\^\(absent\|unreachable\|\(\\\?\|u:object_r:\[a-z0-9_\]\+:s0\)/w\[01\]\)\$`\)' 'regexp.MustCompile(`^\\S+$`)'
mut "M3 a missing key reads absent (T3 _MissingKeyAndNoForeignText)" report_siblings.go \
  'v = "missing"' 'v = "absent"'
mut "M4 an absent file reads unreadable (T4 _AbsentDirNone)" report_siblings.go \
  'return "none \(no roam\.log\)"' 'return "unreadable"'
mut "M5 the key set only when !deviceScope (T6 _BothScopes)" report_issue.go \
  '\tstatus\["bootsweep_siblings"\] = (bootsweepSiblingsStatus\([^\n]*\))' '\tif !deviceScope {\n\t\tstatus["bootsweep_siblings"] = \1\n\t}'
mut "M6 the tail bound removed, the file read from its start (T5 _TailBound)" report_siblings.go \
  'st\.Size\(\) > bootsweepSiblingsTailBytes' 'false && st.Size() > bootsweepSiblingsTailBytes'
mut "M7 the prefix test loosened to Contains \"siblings:\" (T1 _LastRoamdLineWins)" report_siblings.go \
  'strings\.HasPrefix\(ln, bootsweepSiblingsPrefix\)' 'strings.Contains(ln, "siblings:")'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
