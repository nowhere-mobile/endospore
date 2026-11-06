#!/usr/bin/env bash
# run.sh <OtaWindow.java> <ChooserActivity.java> <OtaTimeReceiver.java> <AndroidManifest.xml> <NowhereApp.java>
# -- NWP-20261025-14: compile the REAL OtaWindow (unchanged), run OtaWindowCases, then pin ChooserActivity.nowWithinWindow's
# body. NWP-20261108-08: the cases cover nextStartMillis and installAtAlarm, and the source pins hold the preferred-time
# alarm (OtaTimeReceiver, its manifest entry, its arm sites) -- comments dropped first, so prose cannot satisfy a pin.
# $JAVAC / $JAVA come from core/chooser/test-ota-window-java.sh.
# Exit codes: 1 = a case or a pin failed; 3 = the sources did not compile, or the JVM died with anything but 0/1.
set -euo pipefail
U="usage: run.sh OtaWindow.java ChooserActivity.java OtaTimeReceiver.java AndroidManifest.xml NowhereApp.java"
SRC="${1:?$U}"
ACT="${2:?$U}"
RCV="${3:?$U}"
MAN="${4:?$U}"
APP="${5:?$U}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${OTA_WINDOW_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$SRC" "$D/src/com/nowhere/chooser/OtaWindow.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" "$D/src/com/nowhere/chooser/OtaWindow.java" "$here/OtaWindowCases.java" \
    2>"$D/javac.err" || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.OtaWindowCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# Source pin: nowWithinWindow delegates to OtaWindow.within and keeps no arithmetic of its own.
body=$(awk '/private boolean nowWithinWindow\(String hhmm\) \{/{f=1} f{print} f&&/^    }$/{exit}' "$ACT")
[ -n "$body" ] || { echo "--- FAIL: pin: nowWithinWindow not found in $ACT"; exit 1; }
case "$body" in
  *"OtaWindow.within(hhmm,"*) echo "--- PASS: pin: nowWithinWindow calls OtaWindow.within(hhmm," ;;
  *) echo "--- FAIL: pin: nowWithinWindow does not call OtaWindow.within(hhmm,"; rc=1 ;;
esac
case "$body" in
  *set*|*diff*) echo "--- FAIL: pin: nowWithinWindow still does arithmetic on set/diff"; rc=1 ;;
  *) echo "--- PASS: pin: no set/diff arithmetic left in nowWithinWindow" ;;
esac

# ---- NWP-20261108-08: the preferred-time alarm. Pins read comment-free copies (string-literal aware).
strip_java() { perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gse' "$1"; }
strip_java "$RCV" > "$D/rcv.java"
strip_java "$ACT" > "$D/act.java"
strip_java "$APP" > "$D/app.java"
perl -0pe 's/<!--.*?-->//gs' "$MAN" > "$D/man.xml"

pin() { # pin <name> <command...>: PASS when the command succeeds
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "--- PASS: pin: $name"; else echo "--- FAIL: pin: $name"; rc=1; fi
}
# body <file> <signature text>: the method from its signature (a literal substring) to the closing brace at four-space indent.
body() { awk -v sig="$2" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$1"; }
body "$D/rcv.java" 'public void onReceive(' > "$D/onReceive.txt"
body "$D/rcv.java" 'static void arm(Context ctx, String hhmm)' > "$D/arm.txt"
body "$D/rcv.java" 'static void armFromDaemon(' > "$D/armFromDaemon.txt"
body "$D/act.java" 'protected void onResume() {' > "$D/onResume.txt"
body "$D/act.java" 'private void showOtaTimePicker(' > "$D/picker.txt"
for f in onReceive arm armFromDaemon onResume picker; do
  [ -s "$D/$f.txt" ] || { echo "--- FAIL: pin: $f not found"; rc=1; }
done
O="$D/onReceive.txt"

# 1. onReceive re-arms from the extra before goAsync, and finishes the PendingResult in a finally.
pin "onReceive arms from the extra before goAsync" perl -0ne 'exit !(/arm\(app, intent\.getStringExtra\(EXTRA\)\);.*goAsync\(\)/s)' "$O"
pin "onReceive finishes the PendingResult in a finally" perl -0ne 'exit !(/finally\s*\{\s*\w+\.finish\(\);/)' "$O"
# 2. OTA-APPLY appears once in the receiver, inside the block of `if (OtaWindow.installAtAlarm(`.
pin "the OTA-APPLY verb is sent once in the receiver" test "$(grep -c '"OTA-APPLY\\n"' "$D/rcv.java")" = 1
pin "OTA-APPLY only inside the installAtAlarm block" perl -0ne '
  exit 1 unless /if \(OtaWindow\.installAtAlarm\(/g;
  my $at = pos($_); my $start = index($_, "{", $at); exit 1 if $start < 0;
  my ($d, $i) = (0, $start); my $end = -1;
  for (; $i < length($_); $i++) { my $c = substr($_, $i, 1); $d++ if $c eq "{"; if ($c eq "}") { $d--; if ($d == 0) { $end = $i; last } } }
  my $a = index($_, "\"OTA-APPLY\\n\""); exit !($a > $start && $a < $end)' "$O"
pin "a timed PARTIAL_WAKE_LOCK is acquired before OTA-APPLY, inside the installAtAlarm block" perl -0ne '
  exit !(/if \(OtaWindow\.installAtAlarm\([^{]*\{[^}]*?newWakeLock\([^;]*PARTIAL_WAKE_LOCK[^;]*\)\.acquire\(\d[\d_]*\);[^}]*?"OTA-APPLY\\n"/s)' "$O"
# 3. held is the last argument, comes from autoInstallHeld, and both cold-lock reads follow the OTA-STATUS read.
pin "installAtAlarm is passed held" grep -Eq 'installAtAlarm\([^;{]*, held\)\) \{' "$O"
pin "held comes from OtaUpdate.autoInstallHeld" grep -q 'held = OtaUpdate\.autoInstallHeld(' "$O"
pin "both GET-COLDLOCK reads follow the OTA-STATUS read" perl -0ne '
  exit 1 unless /"OTA-STATUS\\n"(.*)$/s; my $after = $1;
  exit !($after =~ /"GET-COLDLOCK\\n"/ && $after =~ /"GET-COLDLOCK-PENDING\\n"/)' "$O"
# 4. live reads an unlocked secondary user, not sessionLive alone.
pin "live reads isUserUnlocked over the secondary users" grep -q 'isUserUnlocked(' "$D/rcv.java"
pin "live reads getSecondaryUsers" grep -q 'getSecondaryUsers(' "$D/rcv.java"
pin "live reads ChooserActivity.isSessionLive()" grep -q 'ChooserActivity\.isSessionLive()' "$D/rcv.java"
# 5. exact RTC_WAKEUP, never allow-while-idle.
pin "arm uses setExact with RTC_WAKEUP" grep -q 'setExact(AlarmManager\.RTC_WAKEUP' "$D/arm.txt"
pin "no allow-while-idle alarm in the receiver" test "$(grep -c 'AllowWhileIdle' "$D/rcv.java")" = 0
# 6. the user-0 guard in arm, armFromDaemon (before it starts a thread) and onReceive (before it arms).
G='UserHandle\.myUserId\(\) != 0\) return;'
pin "user-0 guard in arm" perl -0ne "exit !(/$G/)" "$D/arm.txt"
pin "user-0 guard in armFromDaemon before the thread" perl -0ne "exit !(/$G.*new Thread\(/s)" "$D/armFromDaemon.txt"
pin "user-0 guard in onReceive before the first arm" perl -0ne "exit !(/$G.*arm\(/s)" "$O"
# 7. the request code collides with none of the package's alarms (0 idle, 1 wipe, 1519 gate, 824 OTA wake).
req=$(sed -n 's/.*private static final int REQ = \([0-9][0-9]*\);.*/\1/p' "$D/rcv.java")
case "$req" in
  ""|0|1|1519|824) echo "--- FAIL: pin: request code '$req' is missing or collides with another alarm"; rc=1 ;;
  *) echo "--- PASS: pin: request code $req is distinct" ;;
esac
pin "the alarm's PendingIntent uses REQ" grep -q 'getBroadcast(app, REQ,' "$D/arm.txt"
# 8. the manifest declares the receiver, not exported.
pin "manifest declares .OtaTimeReceiver exported=false" perl -0ne '
  my @m = /<receiver\s+android:name="\.OtaTimeReceiver"/g; exit 1 unless @m == 1;
  exit !(/<receiver\s+android:name="\.OtaTimeReceiver"\s+android:exported="false"\s*\/>/)' "$D/man.xml"
# 9-11. the arm sites.
pin "NowhereApp calls OtaTimeReceiver.armFromDaemon(this)" grep -q 'OtaTimeReceiver\.armFromDaemon(this);' "$D/app.java"
pin "onResume calls armFromDaemon" grep -q 'OtaTimeReceiver\.armFromDaemon(getApplicationContext());' "$D/onResume.txt"
pin "the time picker arms after a saved Set" grep -q 'OtaTimeReceiver\.arm(getApplicationContext(), hhmm);' "$D/picker.txt"
pin "the time picker cancels after a saved Any time" grep -q 'OtaTimeReceiver\.cancel(getApplicationContext());' "$D/picker.txt"
exit "$rc"
