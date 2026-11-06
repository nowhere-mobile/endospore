#!/usr/bin/env bash
# test-state-tmpfs.sh [--mutate] -- runs the TestStateTmpfs_* tests (NWP-20261117-07, decision #30: sign-in, create and
# resume answer ERR-NOTMPFS when the state dir is definitely not a tmpfs) with the tests that drive the same arms;
# --mutate re-runs them with each guard broken in turn (main.go, state_tmpfs.go, report_issue.go), restoring every file
# on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go state_tmpfs.go report_issue.go)
restore() {
  local f
  for f in "${FILES[@]}"; do
    [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"
  done
  return 0
}
trap 'restore; rm -rf "$W"' EXIT
RUN=(go test -count=1 -timeout 300s -run 'TestStateTmpfs|TestGateOnly|TestLegacyLogin|TestDaemonVerbs' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
vout=$(go vet ./... 2>&1); vrc=$?
[ $vrc -eq 0 ] || { printf '%s\n' "$vout"; echo "FAILED: go vet"; exit 1; }
echo "go vet ./...: ok"
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f.orig" || exit 2; done
fails=0
mut() { # mut <label> <file> <regex pattern> <repl>
  local label="$1" file="$2" res mrc
  if ! python3 - "$file" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return
  fi
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  restore
}
ARM='\n\t\tif refuseNoTmpfs\(conn, dest\) \{'
mut "M1 CREATE call removed" main.go '(if name == "CREATE" \{)'"$ARM" 'if name == "CREATE" {
		if false {'
mut "M2 CREATE-CODE call removed" main.go '(if name == "CREATE-CODE" \{)'"$ARM" 'if name == "CREATE-CODE" {
		if false {'
mut "M3 ROAM-IN call removed" main.go '(if name == "ROAM-IN" \{)'"$ARM" 'if name == "ROAM-IN" {
		if false {'
mut "M4 ROAM-IN-OFFLINE call removed" main.go '(if name == "ROAM-IN-OFFLINE" \{)'"$ARM" 'if name == "ROAM-IN-OFFLINE" {
		if false {'
mut "M5 SEED-SSAID call removed" main.go '(if name == "SEED-SSAID" \{)'"$ARM" 'if name == "SEED-SSAID" {
		if false {'
mut "M6 FIDO2 NFC arm call removed" main.go '(if name == "FIDO2-NFC-ASSERT" \|\| name == "FIDO2-NFC-RESUME" \{)'"$ARM" 'if name == "FIDO2-NFC-ASSERT" || name == "FIDO2-NFC-RESUME" {
		if false {'
mut "M7 RESUME call removed" main.go '(if name == "RESUME" \{)'"$ARM" 'if name == "RESUME" {
		if false {'
mut "M8 legacy fallthrough call removed" main.go 'refuse on a non-tmpfs\n\tif refuseNoTmpfs\(conn, dest\) \{' 'refuse on a non-tmpfs
	if false {'
mut "M9 a statfs error refused (unknown read as no)" state_tmpfs.go 'if a != tmpfsNo \{\n\t\treturn false' 'if a == tmpfsYes {
		return false'
mut "M10 report key dropped" report_issue.go '\tstatus\["state_tmpfs"\] = stateTmpfsAnswer\.word\(\)\n' '	_ = stateTmpfsAnswer
'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
