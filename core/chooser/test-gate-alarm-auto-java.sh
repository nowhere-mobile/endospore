#!/usr/bin/env bash
# test-gate-alarm-auto-java.sh [--mutate] -- GateAlarmAuto (when an unattended gate alarm snoozes or dismisses itself),
# compiled UNCHANGED under javac and RUN, plus pins on GateAlarmActivity, GateAlarmReceiver, ChooserActivity and
# core/agent/gate_log.go (NWP-20261116-12).
#
# WHY THIS IS COMMITTED. GateAlarmActivity rang until Snooze, Dismiss or a volume key, so a phone in a drawer rang, screen
# on, until its battery died. dn-1023 #12 and #64 (dn-1110 #2) decided: unanswered for 10 minutes it snoozes itself, three
# times, and the next unattended ring is dismissed. The cases pin the timer's value and the count; the pins pin where the
# timer is posted and cancelled, and that the count rides alarm -> receiver -> activity. No check waits 10 minutes.
# NWP-20261128-34: the pins also hold that a volume press, after it silences the ring, releases the screen-on hold.
# What it does NOT prove: a device ring, or that the full chooser compiles (the build host does that).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-gate-alarm-auto-java.sh            # the cases and the pins
#   bash test-gate-alarm-auto-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CH="$HERE/src/com/nowhere/chooser"
SRC="$CH/GateAlarmAuto.java"
ACT="$CH/ChooserActivity.java"
GAT="$CH/GateAlarmActivity.java"
RCV="$CH/GateAlarmReceiver.java"
GOL="$HERE/../agent/gate_log.go"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/gate-alarm-auto/run.sh"
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
for f in "$SRC" "$ACT" "$GAT" "$RCV" "$GOL" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export GATE_ALARM_AUTO_TMP="$W"

# suite <Auto> <ChooserActivity> <GateAlarmActivity> <GateAlarmReceiver> <gate_log.go> -> run.sh's code:
# 0 pass, 1 a case or pin failed (only this may convict), 3 no compile.
suite() { bash "$RUN" "$1" "$2" "$3" "$4" "$5"; }

echo "== $SRC"
out=$(suite "$SRC" "$ACT" "$GAT" "$RCV" "$GOL" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <file: auto|act|gat|rcv|go> <perl-expr>
  local d m rc o orig s a g r gl; d=$(mktemp -d -p "$W")
  s="$SRC"; a="$ACT"; g="$GAT"; r="$RCV"; gl="$GOL"
  case "$2" in
    auto) orig="$SRC"; m="$d/GateAlarmAuto.java"; s="$m" ;;
    act)  orig="$ACT"; m="$d/ChooserActivity.java"; a="$m" ;;
    gat)  orig="$GAT"; m="$d/GateAlarmActivity.java"; g="$m" ;;
    rcv)  orig="$RCV"; m="$d/GateAlarmReceiver.java"; r="$m" ;;
    go)   orig="$GOL"; m="$d/gate_log.go"; gl="$m" ;;
    *) echo "  ERROR     $1 -- unknown file kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$s" "$a" "$g" "$r" "$gl" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "A1 RING_MS 9 minutes" auto 's/RING_MS = 10 \* 60 \* 1000L/RING_MS = 9 * 60 * 1000L/' || fails=$((fails+1))
mut "A2 MAX_AUTO_SNOOZES 2" auto 's/MAX_AUTO_SNOOZES = 3;/MAX_AUTO_SNOOZES = 2;/' || fails=$((fails+1))
mut "A3 next without the +1" auto 's/return sane\(soFar\) \+ 1;/return sane(soFar);/' || fails=$((fails+1))
mut "A4 the user's snooze() passes next(autoSoFar)" gat \
  's/(System\.currentTimeMillis\(\) \+ SNOOZE_MS)\);/$1, GateAlarmAuto.next(autoSoFar));/' || fails=$((fails+1))
mut "A5 stopRinging without removeCallbacks(unattended)" gat 's/\n\s*h\.removeCallbacks\(unattended\);//' || fails=$((fails+1))
mut "A6 unattended ignores stopped" gat 's/\n\s*if \(stopped\) return;[^\n]*//' || fails=$((fails+1))
mut "A7 the receiver drops the extra" rcv \
  's/GateAlarmAuto\.sane\(intent\.getIntExtra\(GateAlarmAuto\.EXTRA, 0\)\)/0/' || fails=$((fails+1))
mut "A8 gateAlarmPi drops the extra" act \
  's/\n\s*\.putExtra\(GateAlarmAuto\.EXTRA, GateAlarmAuto\.sane\(autoSnoozes\)\);/;/' || fails=$((fails+1))
mut "A9 ui-auto-dismiss removed from gate_log.go" go 's/ "ui-auto-dismiss": true,//' || fails=$((fails+1))
mut "A10 a volume press keeps the screen-on hold" gat \
  's/(stopRinging\(\); \/\/ a volume press[^\n]*(?:\n\s*\/\/[^\n]*)*)\n\s*try \{ getWindow\(\)\.clearFlags\(WindowManager\.LayoutParams\.FLAG_KEEP_SCREEN_ON\); \} catch \(Throwable ignore\) \{\}/$1/' || fails=$((fails+1))
mut "A11 the volume branch releases the hold before it silences the ring" gat \
  's/(stopRinging\(\); \/\/ a volume press[^\n]*)((?:\n\s*\/\/[^\n]*)*\n\s*)(try \{ getWindow\(\)\.clearFlags\(WindowManager\.LayoutParams\.FLAG_KEEP_SCREEN_ON\); \} catch \(Throwable ignore\) \{\})/$3$2$1/' || fails=$((fails+1))
mut "A12 onCreate no longer holds the screen on" gat \
  's/\n\s*getWindow\(\)\.addFlags\(WindowManager\.LayoutParams\.FLAG_KEEP_SCREEN_ON\);//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
