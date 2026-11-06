#!/usr/bin/env bash
# test-ota-window-java.sh [<OtaWindow.java>] [--mutate] -- OtaWindow.within, the preferred-time OTA install window,
# compiled UNCHANGED under javac and RUN (NWP-20261025-14).
#
# WHY THIS IS COMMITTED. nowWithinWindow computed `diff = now - set; diff >= 0 && diff < 60`, so a window that crosses
# midnight lost everything after 00:00 (set 23:50 admitted 23:50-23:59 only; from about 23:46 a 15-minute poll could step
# over it). The arithmetic now lives in OtaWindow and the cases name every edge. M1 below IS the pre-change logic.
# NWP-20261108-08 adds the preferred-time alarm: the cases for OtaWindow.nextStartMillis / installAtAlarm, source pins on
# OtaTimeReceiver, its manifest entry and its arm sites (tests/ota-window/run.sh), and mutants N1-N17.
# What it does NOT prove: the device run -- an install on a phone asleep across the window -- and the receiver's android
# behaviour, which is source-pinned only (the chooser cannot be compiled off the build host).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-ota-window-java.sh            # the cases
#   bash test-ota-window-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/OtaWindow.java"
ACT="$HERE/src/com/nowhere/chooser/ChooserActivity.java"
RCV="$HERE/src/com/nowhere/chooser/OtaTimeReceiver.java"
MAN="$HERE/AndroidManifest.xml"
APP="$HERE/src/com/nowhere/chooser/NowhereApp.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/ota-window/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite did NOT run and does not skip: install a JDK or" \
       "run it on the build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$SRC" "$ACT" "$RCV" "$MAN" "$APP" "$RUN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export OTA_WINDOW_TMP="$W"

# suite <OtaWindow> <ChooserActivity> <OtaTimeReceiver> <AndroidManifest.xml> <NowhereApp> -> run.sh's code: 0 pass,
# 1 a case or pin failed (only this may convict), 3 no compile.
suite() { bash "$RUN" "$1" "$2" "$3" "$4" "$5"; }

echo "== $SRC"
out=$(suite "$SRC" "$ACT" "$RCV" "$MAN" "$APP" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <kind: win|act|rcv|man|app> <perl-expr>
  local d m rc o orig w a r n p f; d=$(mktemp -d -p "$W")
  w="$SRC"; a="$ACT"; r="$RCV"; n="$MAN"; p="$APP"
  case "$2" in
    win) orig="$SRC"; f=OtaWindow.java; m="$d/$f"; w="$m" ;;
    act) orig="$ACT"; f=ChooserActivity.java; m="$d/$f"; a="$m" ;;
    rcv) orig="$RCV"; f=OtaTimeReceiver.java; m="$d/$f"; r="$m" ;;
    man) orig="$MAN"; f=AndroidManifest.xml; m="$d/$f"; n="$m" ;;
    app) orig="$APP"; f=NowhereApp.java; m="$d/$f"; p="$m" ;;
    *) echo "  ERROR     $1 -- unknown mutant kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$w" "$a" "$r" "$n" "$p" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the pre-change logic (diff = now - set; diff >= 0 && diff < 60)" win \
  's/int diff = \(\(nowMinuteOfDay - \(h \* 60 \+ m\)\) % DAY \+ DAY\) % DAY;\n        return diff < WINDOW;/int diff = nowMinuteOfDay - (h * 60 + m);\n        return diff >= 0 && diff < WINDOW;/' || fails=$((fails+1))
mut "M2 < 60 became <= 60" win 's/return diff < WINDOW;/return diff <= WINDOW;/' || fails=$((fails+1))
mut "M3 the + DAY dropped (Java % keeps the sign)" win 's/% DAY \+ DAY\) % DAY;/% DAY);/' || fails=$((fails+1))
mut "M4 the hour bound dropped" win 's/if \(h > 23 \|\| m > 59\)/if (m > 59)/' || fails=$((fails+1))
mut "M5 ChooserActivity's delegation removed" act 's/return OtaWindow\.within\(hhmm, now\);/return now >= 0;/' || fails=$((fails+1))
mut "N1 nextStartMillis drops the add-a-day step" win 's/\n\s*c\.add\(java\.util\.Calendar\.DAY_OF_MONTH, 1\);//' || fails=$((fails+1))
mut "N2 nextStartMillis uses UTC instead of tz" win 's/Calendar\.getInstance\(tz\)/Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))/' || fails=$((fails+1))
mut "N3 installAtAlarm drops held" win 's/\n\s*if \(held\) return false;//' || fails=$((fails+1))
mut "N4 installAtAlarm drops sessionLive" win 's/\n\s*if \(sessionLive\) return false;//' || fails=$((fails+1))
mut "N5 installAtAlarm drops charging" win 's/\n\s*if \(!charging\) return false;//' || fails=$((fails+1))
mut "N6 onReceive's first arm deleted" rcv 's/\n\s*arm\(app, intent\.getStringExtra\(EXTRA\)\);//' || fails=$((fails+1))
mut "N7 setExact -> setExactAndAllowWhileIdle" rcv 's/am\.setExact\(AlarmManager\.RTC_WAKEUP/am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP/' || fails=$((fails+1))
mut "N8 the receiver is exported" man 's/(android:name="\.OtaTimeReceiver"\s+android:exported=)"false"/$1"true"/' || fails=$((fails+1))
mut "N9 the picker's arm deleted" act 's/\n\s*if \(saved\) OtaTimeReceiver\.arm\(getApplicationContext\(\), hhmm\);//' || fails=$((fails+1))
mut "N10 onResume's armFromDaemon deleted" act 's/\n\s*OtaTimeReceiver\.armFromDaemon\(getApplicationContext\(\)\);[^\n]*//' || fails=$((fails+1))
mut "N11 the receiver passes false for held" rcv 's/(OtaWindow\.installAtAlarm\([^;{]*?), held\)\)/$1, false))/' || fails=$((fails+1))
mut "N12 live drops the unlocked-user term" rcv 's/\n\s*if \(um\.isUserUnlocked\(uh\)\) return true;//' || fails=$((fails+1))
mut "N13 OTA-APPLY sent before the installAtAlarm check" rcv 's/(\n(\s*)if \(OtaWindow\.installAtAlarm\()/\n$2DaemonSocket.roundTrip("OTA-APPLY\\n", REPLY_CAP_MS);$1/' || fails=$((fails+1))
mut "N14 NowhereApp's armFromDaemon deleted" app 's/\n\s*OtaTimeReceiver\.armFromDaemon\(this\);//' || fails=$((fails+1))
mut "N15 the OTA-APPLY wakelock dropped" rcv 's/\n[^\n]*newWakeLock\([^\n]*\.acquire\(30_000\);//' || fails=$((fails+1))
mut "N16 the OTA-APPLY wakelock has no timeout" rcv 's/\.acquire\(30_000\);/.acquire();/' || fails=$((fails+1))
mut "N17 the OTA-APPLY wakelock taken after the hand-off" rcv 's/(\n[^\n]*newWakeLock\([^\n]*\.acquire\(30_000\);)(\n[^\n]*"OTA-APPLY\\n"[^\n]*)/$2$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
