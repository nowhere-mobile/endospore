#!/usr/bin/env bash
# test-emergency-window.sh [--mutate] -- runs emergency_window_test.go (NWP-20261206-02, Q047): the login daemon keeps
# the last emergency call's CLOCK_BOOTTIME in RAM; EMERGENCY-MARK records it and EMERGENCY-RECENT answers YES <age_s>
# inside 15 minutes, for the chooser app in any user only, before any lock, with no file. --mutate re-runs the focused
# tests against pristine copies of emergency_window.go and main.go with each rule broken in turn, restoring both files
# on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply, or fails to compile, counts as a
# failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
EMW=emergency_window.go
MAIN=main.go
RUN=(go test -count=1 -run 'EmergencyWindow' .)
W=$(mktemp -d) || exit 2
trap '[ -f "$W/emergency_window.go.orig" ] && cp -f "$W/emergency_window.go.orig" "$EMW"; [ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
mkdir -p "$W/tmp" && export TMPDIR="$W/tmp" GOTMPDIR="$W/tmp"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$EMW" "$W/emergency_window.go.orig"
cp "$MAIN" "$W/main.go.orig"
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement> <the test that must convict it>
  local label=$1 file=$2 pat=$3 rep=$4 want=$5 res
  python3 - "$file" "$pat" "$rep" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$file.orig" "$file"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *"--- FAIL: $want "* ]]; then echo "  convicted $label (by $want)"
  else
    if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $label -- did not compile"
    elif [[ "$res" == *'--- FAIL'* ]]; then echo "  MISSED    $label -- failed, but not in $want"
    else echo "  SURVIVED  $label"; fi
    fails=$((fails+1))
  fi
  cp -f "$W/$file.orig" "$file"
}
mut "M1 the window check removed" "$EMW" 'if age < emergencyCallbackWindowMs \{' 'if age >= 0 {' TestEmergencyWindowExpires
mut "M2 the window end inclusive" "$EMW" 'if age < emergencyCallbackWindowMs \{' 'if age <= emergencyCallbackWindowMs {' TestEmergencyWindowExpires
mut "M3 every caller admitted" "$EMW" '(func emergencyCallerOK\(uid int\) bool \{\n)' '\1\treturn true\n' TestEmergencyWindowRefusesOtherCallers
mut "M4 the whole uid compared, not the appId" "$EMW" 'uid%100000 == app' 'uid == app' TestEmergencyWindowSurvivesUserSwitch
mut "M5 the handler waits on sessionMu" "$EMW" '(func handleEmergencyWindow\(conn net\.Conn, name string\) \{\n)' '\1\tsessionMu.Lock()\n\tdefer sessionMu.Unlock()\n' TestEmergencyWindowNeverWaitsOnLocks
mut "M6 MARK writes a file under dest" "$MAIN" '(\tif name == "EMERGENCY-MARK" \|\| name == "EMERGENCY-RECENT" \{\n)' '\1\t\tif name == "EMERGENCY-MARK" {\n\t\t\tos.WriteFile(filepath.Join(dest, "emergency-mark"), nil, 0o600)\n\t\t}\n' TestEmergencyWindowRAMOnly
mut "M7 an unreadable clock answers NO" "$EMW" 'fmt\.Fprint\(conn, "YES 0\\n"\)' 'fmt.Fprint(conn, "NO\\n")' TestEmergencyWindowClockUnreadable
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
