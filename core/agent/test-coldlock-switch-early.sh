#!/usr/bin/env bash
# test-coldlock-switch-early.sh [--mutate] -- NWP-20261121-01: a committed cold lock publishes the switch to the gate
# right after btpark and the release* calls, runs the alarm relay and the media sweep behind it, and publishes the
# LOCK after them; a RESUME while that teardown runs answers ERR-WORKER-BUSY; the chooser's SWITCH arm re-arms the
# "Locking..." cover. Runs the Go tests and the chooser pin; --mutate re-runs them against a COPY of the package (and
# of ChooserActivity.java) with each part broken in turn. Each mutant must be CONVICTED by a `--- FAIL` or by the
# pin's named failure; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestColdLockTouchesNothing|TestColdLockPreStopSteps|TestColdLockSwitchEarly|TestResumeRefusedWhileTeardown' .)
CHOOSER=../chooser/src/com/nowhere/chooser/ChooserActivity.java

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

# chooser_pin <file>: the SWITCH arm of ensureReapWatcher re-arms the cover beside coldWakeAcquire, and only when the
# switch actually fronts the gate (user 0 not already in front). Prints PIN failures; returns non-zero on any.
chooser_pin() {
  local f="$1" body c1 c2 rc=0
  body=$(python3 - "$f" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.find("static void ensureReapWatcher(Context ctx) {")
if i < 0:
    sys.exit(1)
j = s.find("\n    }\n", i)
print(s[i:j if j > 0 else len(s)])
PY
) || { echo "PIN C0 ensureReapWatcher not found in $f -- the pins below prove nothing"; return 1; }
  c1=$(grep -cF 'if (cold) { coldWakeAcquire(app); if (android.app.ActivityManager.getCurrentUser() != 0) markColdLockIncoming(); }' <<<"$body")
  if [ "$c1" != 1 ]; then
    echo "PIN C1 the SWITCH arm does not re-arm the cold-lock cover (markColdLockIncoming beside coldWakeAcquire)"
    rc=1
  fi
  c2=$(grep -cF 'coldWakeAcquire(app); markColdLockIncoming();' <<<"$body")
  if [ "$c2" != 0 ]; then
    echo "PIN C2 the SWITCH arm re-arms the cover with user 0 already in front"
    rc=1
  fi
  return "$rc"
}

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
pin=$(chooser_pin "$CHOOSER"); prc=$?
if [ "$prc" -ne 0 ]; then
  echo "$pin"
  echo "FAIL: the chooser pin"
  exit 1
fi
echo "ok: the chooser pin"
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# apply <file> <python-regex> <replacement>: one match exactly, or it fails.
apply() {
  python3 - "$1" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
}
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the tests there, then restore the file.
mut() {
  local label="$1" f="$2" res
  cp "$P/$f" "$W/orig.go"
  if apply "$P/$f" "$3" "$4"; then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $label"
    else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
# jmut <label> <want-pin> <python-regex> <replacement>: mutate a copy of ChooserActivity.java; the pin must fail by name.
jmut() {
  local label="$1" want="$2" jf res
  jf=$(mktemp -p "$W") || exit 2
  cp "$CHOOSER" "$jf"
  if apply "$jf" "$3" "$4"; then
    res=$(chooser_pin "$jf")
    if [[ "$res" == *"$want "* ]]; then echo "  convicted $label"
    else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
}
SW='\tpendingReapMu\.Lock\(\)\n\tpendingSwitchUID = uid // phase 1: switch to the gate\n\tpendingReapMu\.Unlock\(\)\n'
mut "M1 the switch moved back below the sweep" main.go \
  "($SW)(.*?\\tcoldLockSweepMedia\\(dest, name, pass, uid\\)\\n)" '\2\1'
mut "M2 the switch moved above btpark" main.go \
  "(\\tif out := coldLockWorker\\(dest, \"btpark\".*?)($SW)" '\2\1'
mut "M3 pendingLockUID published with the switch" main.go \
  '\tpendingSwitchUID = uid // phase 1: switch to the gate\n(.*?)\tpendingReapMu\.Lock\(\)\n\tpendingLockUID = uid // phase 2b[^\n]*\n\tpendingReapMu\.Unlock\(\)\n' \
  '\tpendingSwitchUID = uid // phase 1: switch to the gate\n\tpendingLockUID = uid\n\1'
mut "M4 the handleResume guard removed" main.go \
  '\tif coldLockTeardownRunningFor\(uid\) \{\n.*?\t\tbusy\(\)\n\t\treturn\n\t\}\n' ''
mut "M5 the guard ignores the uid" main.go \
  'return coldLockRunning && coldLockUID == uid && uid != ""' 'return coldLockRunning'
jmut "M6 markColdLockIncoming removed from the SWITCH arm" "PIN C1" \
  'if \(cold\) \{ coldWakeAcquire\(app\); if \(android\.app\.ActivityManager\.getCurrentUser\(\) != 0\) markColdLockIncoming\(\); \}' \
  'if (cold) coldWakeAcquire(app);'
jmut "M7 the user-0 guard removed from the SWITCH arm" "PIN C2" \
  'if \(cold\) \{ coldWakeAcquire\(app\); if \(android\.app\.ActivityManager\.getCurrentUser\(\) != 0\) markColdLockIncoming\(\); \}' \
  'if (cold) { coldWakeAcquire(app); markColdLockIncoming(); }'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
