#!/usr/bin/env bash
# test-missed-call-java.sh [--mutate] -- NWP-20261012-07: Telecom never posts its own missed-call notification in
# user 0. Runs core/chooser/tests/missed-call: MissedCallReceiver's decision, compiled and EXECUTED, the manifest entry
# that makes Telecom hand the broadcast to the chooser, and the wiring around them (tests/missed-call/run.sh says how).
#
# WHY THIS IS COMMITTED. Every SIM call is also written to user 0's call log, and at every switch back to user 0 -- a
# sign-out -- Telecom re-reads that log and shows its unread missed calls. It posts that notification ITSELF, in user 0,
# with the caller's number in the clear, unless user 0's default dialer (the chooser) declares a receiver for
# ACTION_SHOW_MISSED_CALLS_NOTIFICATION; then it sends the dialer the broadcast and posts nothing. Chester, 2026-10-12:
# "after logging off, lock screen shows missed call". The receiver is one manifest entry, and its absence is silent: no
# build break, no log line, only the caller's number back on the lock screen; so is a <data> added to its filter, which
# makes Telecom's query miss it. Its scrub must also never run in a roamed user, whose call log is that session's own,
# and the receiver is disabled in every roamed user at sign-in, so that user's own missed-call notices are never taken.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips would read green on a runner that never ran
# it. javac/java come from PATH, then the build VM's prebuilt JDK 21. --mutate re-runs it against deliberately broken
# copies, each of which must fail a CASE or a PIN (a copy that no longer extracts or compiles convicts nothing and is
# reported).
#
#   bash test-missed-call-java.sh            # the cases
#   bash test-missed-call-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/missed-call/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-missed-call-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

echo "== $CH"
bash "$RUN" "$CH" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by a case or a pin: a mutant that does not extract or compile proves nothing)"
M=$(mktemp -d)
trap 'rm -rf "$M"' EXIT
mut() { # mut <label> <file under the chooser dir> <perl-expr>
  local rc
  rm -rf "$M/c"; mkdir -p "$M/c/src/com/nowhere/chooser"
  cp "$CH"/src/com/nowhere/chooser/*.java "$M/c/src/com/nowhere/chooser/"
  cp "$CH/AndroidManifest.xml" "$M/c/"
  local f="$M/c/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$f" "$CH/$2"; then echo "  INERT     $1"; return 1; fi
  bash "$RUN" "$M/c" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
R=src/com/nowhere/chooser/MissedCallReceiver.java
C=src/com/nowhere/chooser/ChooserActivity.java
I=src/com/nowhere/chooser/NowhereInCallService.java
X=AndroidManifest.xml
S=src/com/nowhere/chooser/TelScrub.java
fails=0
mut "D1 a roamed user's call log scrubbed"             $R 's/        if \(userId != 0\) return DROP;\n//' || fails=$((fails+1))
mut "D2 the dismiss echo scrubs and cancels again"      $R 's/        if \(count == 0\) return DROP;\n//' || fails=$((fails+1))
mut "D3 any action acted on"                            $R 's/        if \(!ACTION\.equals\(action\)\) return DROP;\n//' || fails=$((fails+1))
mut "D4 a roamed user tested as non-zero the wrong way" $R 's/if \(userId != 0\) return DROP;/if (userId < 0) return DROP;/' || fails=$((fails+1))
mut "D5 the action misspelt"                            $R 's/action\.SHOW_MISSED_CALLS_NOTIFICATION";/action.SHOW_MISSED_CALL_NOTIFICATION";/' || fails=$((fails+1))
mut "D6 the count extra misspelt"                       $R 's/extra\.NOTIFICATION_COUNT";/extra.NOTIFICATION_COUNTS";/' || fails=$((fails+1))
mut "W1 an absent count read as a dismiss"              $R 's/getIntExtra\(EXTRA_COUNT, -1\)/getIntExtra(EXTRA_COUNT, 0)/' || fails=$((fails+1))
mut "W2 no scrub"                                       $R 's/                TelScrub\.callLog\(app\);\n//' || fails=$((fails+1))
mut "W3 no cancel"                                      $R 's/                if \(tm != null\) tm\.cancelMissedCallsNotification\(\);\n//' || fails=$((fails+1))
mut "W4 the async hold never released"                  $R 's/                pr\.finish\(\);\n//' || fails=$((fails+1))
mut "W5 the plan ignored"                               $R 's/        if \(plan != SCRUB_RESET\) return;\n//' || fails=$((fails+1))
mut "W6 the receiver logs the caller's number"          $R 's/(final int count = [^\n]*\n)/$1        final String num = intent.getStringExtra("android.telecom.extra.NOTIFICATION_PHONE_NUMBER");\n/' || fails=$((fails+1))
mut "X1 the receiver not declared"                      $X 's/    <receiver android:name="\.MissedCallReceiver".*?<\/receiver>\n//s' || fails=$((fails+1))
mut "X2 the receiver not exported"                      $X 's/(<receiver android:name="\.MissedCallReceiver" android:exported=)"true"/$1"false"/' || fails=$((fails+1))
mut "X3 the receiver demands a permission"              $X 's/(<receiver android:name="\.MissedCallReceiver")/$1 android:permission="android.permission.BIND_INCALL_SERVICE"/' || fails=$((fails+1))
mut "X4 the receiver disabled"                          $X 's/(<receiver android:name="\.MissedCallReceiver")/$1 android:enabled="false"/' || fails=$((fails+1))
mut "X5 the receiver filters the wrong action"          $X 's/(<action android:name="android\.telecom\.action\.)SHOW_MISSED_CALLS_NOTIFICATION"/$1SHOW_MISSED_CALL_NOTIFICATION"/' || fails=$((fails+1))
mut "X6 the filter names another class"                 $X 's/<receiver android:name="\.MissedCallReceiver"/<receiver android:name=".MissedCallsReceiver"/' || fails=$((fails+1))
mut "X7 READ_PHONE_STATE no longer requested"           $X 's/  <uses-permission android:name="android\.permission\.READ_PHONE_STATE"\/>\n//' || fails=$((fails+1))
mut "G1 the gate-return cancel dropped"                 $C 's/            NowhereInCallService\.cancelFrameworkMissedCall\(app\);\n//' || fails=$((fails+1))
mut "G2 the gate-return scrub dropped"                  $C 's/(            final android\.content\.Context app = getApplicationContext\(\);\n)            TelScrub\.all\(app\);\n/$1/' || fails=$((fails+1))
mut "G3 the framework cancel never called"              $I 's/(try \{ )tm\.cancelMissedCallsNotification\(\);( \} catch \(Throwable ignore\) \{\})/$1$2/' || fails=$((fails+1))
# round 2: the filter's shape, the enabled attribute, the wiring pins, and the roamed-user disable
mut "N2 a <data> in the filter (Telecom's query then misses it)" $X 's/(<action android:name="android\.telecom\.action\.SHOW_MISSED_CALLS_NOTIFICATION"\/>\n)/$1        <data android:scheme="tel"\/>\n/' || fails=$((fails+1))
mut "N2b a category in the filter"                    $X 's/(<action android:name="android\.telecom\.action\.SHOW_MISSED_CALLS_NOTIFICATION"\/>\n)/$1        <category android:name="android.intent.category.DEFAULT"\/>\n/' || fails=$((fails+1))
mut "N2c a second action in the filter"               $X 's/(<action android:name="android\.telecom\.action\.SHOW_MISSED_CALLS_NOTIFICATION"\/>\n)/$1        <action android:name="android.intent.action.BOOT_COMPLETED"\/>\n/' || fails=$((fails+1))
mut "N2d a second intent-filter"                      $X 's/(<receiver android:name="\.MissedCallReceiver" android:exported="true">\n)/$1      <intent-filter><action android:name="android.intent.action.BOOT_COMPLETED"\/><\/intent-filter>\n/' || fails=$((fails+1))
mut "N9 enabled from a resource"                      $X 's/(<receiver android:name="\.MissedCallReceiver")/$1 android:enabled="\@bool\/missed_call_receiver"/' || fails=$((fails+1))
mut "N1 the cancel without its null check"            $R 's/if \(tm != null\) tm\.cancelMissedCallsNotification\(\);/tm.cancelMissedCallsNotification();/' || fails=$((fails+1))
mut "N6 the thread never started"                     $R 's/"nowhere-scrub-missed"\)\.start\(\);/"nowhere-scrub-missed");/' || fails=$((fails+1))
mut "N5 the async hold released at once"              $R 's/(final PendingResult pr = goAsync\(\);\n)/$1        pr.finish();\n/' || fails=$((fails+1))
mut "N5b pr.finish outside the finally"               $R 's/(                if \(tm != null\) tm\.cancelMissedCallsNotification\(\);\n)/$1                pr.finish();\n/; s/            \} finally \{\n                pr\.finish\(\);\n            \}\n//' || fails=$((fails+1))
mut "N3a one framework cancel, not four"              $I 's/for \(int i = 0; i < 4; i\+\+\) \{\n            try \{ tm\.cancelMissedCallsNotification/for (int i = 0; i < 1; i++) {\n            try { tm.cancelMissedCallsNotification/' || fails=$((fails+1))
mut "N3b no pause between the cancels"                $I 's/try \{ Thread\.sleep\(400\); \}/try { Thread.sleep(0); }/' || fails=$((fails+1))
mut "N4 the call-log delete narrowed to missed calls" $S 's/delete\(CallLog\.Calls\.CONTENT_URI, null, null\)/delete(CallLog.Calls.CONTENT_URI, "type = 3", null)/' || fails=$((fails+1))
mut "N7 the #197 Recorder no longer cancels"          $I 's/^                    cancelFrameworkMissedCall\(app\);\n//m' || fails=$((fails+1))
mut "F3a nothing disabled in a roamed user"           $C 's/return new String\[\]\{"\.MissedCallReceiver"\};/return new String[]{};/' || fails=$((fails+1))
mut "F3b the user-0 guard removed"                    $C 's/(private void disableRoamedDialerComponents\(int uid\) \{\n)        if \(uid <= 0\) return;\n/$1/' || fails=$((fails+1))
mut "F3c the guard lets user 0 through"               $C 's/(private void disableRoamedDialerComponents\(int uid\) \{\n        if \(uid )<= 0/$1< 0/' || fails=$((fails+1))
mut "F3d the sign-in never disables it"               $C 's/                disableRoamedDialerComponents\(fuid\); \/\/ NWP-20261012-07[^\n]*\n//' || fails=$((fails+1))
mut "F3e the component enabled instead"               $C 's/(for \(String c : roamedDialerComponents\(\)\) \{\n(?:[^\n]*\n){3}\s*android\.content\.pm\.PackageManager\.)COMPONENT_ENABLED_STATE_DISABLED/$1COMPONENT_ENABLED_STATE_ENABLED/' || fails=$((fails+1))
mut "F3f the gate also disables it in user 0"         $C 's/(            NowhereInCallService\.cancelFrameworkMissedCall\(app\);\n        \}, "nowhere-scrub-gate"\)\.start\(\);\n)/$1        disableRoamedDialerComponents(0);\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
