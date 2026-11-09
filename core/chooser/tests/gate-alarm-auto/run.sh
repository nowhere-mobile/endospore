#!/usr/bin/env bash
# run.sh <GateAlarmAuto.java> <ChooserActivity.java> <GateAlarmActivity.java> <GateAlarmReceiver.java> <gate_log.go> --
# NWP-20261116-12: compile the REAL GateAlarmAuto (unchanged), run GateAlarmAutoCases, then pin the chooser call sites
# on comment-stripped text. $JAVAC / $JAVA come from core/chooser/test-gate-alarm-auto-java.sh. No pin waits for the
# 10-minute timer: it is pinned by value (the cases) and by position (onCreate, stopRinging, unattended).
# NWP-20261128-34: dispatchKeyEvent's volume branch silences the ring, then releases the screen-on hold.
# Exit codes: 1 = a case or a pin failed; 3 = no compile, or the JVM died with anything but 0/1.
set -euo pipefail
U="usage: run.sh GateAlarmAuto.java ChooserActivity.java GateAlarmActivity.java GateAlarmReceiver.java gate_log.go"
SRC="${1:?$U}"
ACT="${2:?$U}"
GAT="${3:?$U}"
RCV="${4:?$U}"
GOL="${5:?$U}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${GATE_ALARM_AUTO_TMP:?set by test-gate-alarm-auto-java.sh}")
trap 'rm -rf "$D"' EXIT
for f in "$SRC" "$ACT" "$GAT" "$RCV" "$GOL"; do [ -f "$f" ] || { echo "run.sh: missing $f" >&2; exit 3; }; done

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$SRC" "$D/src/com/nowhere/chooser/GateAlarmAuto.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" "$D/src/com/nowhere/chooser/GateAlarmAuto.java" "$here/GateAlarmAutoCases.java" \
    2>"$D/javac.err" || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.GateAlarmAutoCases "$GOL" "$GAT" "$RCV" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# strip: drop /* ... */ and // comments from stdin (extract first, strip second).
strip() { perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g'; }
# method <file> <literal signature>: from the FIRST line holding the signature to the next "    }" line, comments stripped.
method() { awk -v sig="$2" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$1" | strip; }
# field <file> <literal start>: from the line holding start to the next "    };" line (a lambda field), comments stripped.
field() { awk -v sig="$2" 'index($0, sig) {f=1} f{print} f&&/^    };$/{exit}' "$1" | strip; }
# pin <name> <body> <must contain> [<must NOT contain>]
pin() {
  local name="$1" body="$2" has="$3" hasnt="${4:-}"
  if [ -z "$body" ]; then echo "--- FAIL: pin: $name: not found"; rc=1; return; fi
  case "$body" in
    *"$has"*) echo "--- PASS: pin: $name has $has" ;;
    *) echo "--- FAIL: pin: $name lacks $has"; rc=1 ;;
  esac
  if [ -n "$hasnt" ]; then
    case "$body" in
      *"$hasnt"*) echo "--- FAIL: pin: $name still has $hasnt"; rc=1 ;;
      *) echo "--- PASS: pin: $name has no $hasnt" ;;
    esac
  fi
}
# before <name> <body> <first> <then>: <first> appears, and strictly before <then>
before() {
  local name="$1" body="$2" a="$3" b="$4" pa pb
  pa=${body%%"$a"*}; pb=${body%%"$b"*}
  case "$body" in *"$a"*) ;; *) echo "--- FAIL: order: $name lacks $a"; rc=1; return ;; esac
  case "$body" in *"$b"*) ;; *) echo "--- FAIL: order: $name lacks $b"; rc=1; return ;; esac
  if [ "${#pa}" -lt "${#pb}" ]; then echo "--- PASS: order: $name: $a before $b"; else echo "--- FAIL: order: $name: $a not before $b"; rc=1; fi
}
# ends <name> <body> <suffix>: the body, trailing whitespace removed, ends with suffix
ends() {
  local name="$1" body="$2" s="$3" t
  t="${body%"${body##*[![:space:]]}"}"
  case "$t" in *"$s") echo "--- PASS: pin: $name ends with $s" ;; *) echo "--- FAIL: pin: $name does not end with $s"; rc=1 ;; esac
}

# GateAlarmActivity.onCreate: the count is read after the user-0 guard; the timer is posted after the ring starts.
READ='autoSoFar = GateAlarmAuto.sane(getIntent().getIntExtra(GateAlarmAuto.EXTRA, 0));'
POST='h.postDelayed(unattended, GateAlarmAuto.RING_MS);'
oc=$(method "$GAT" 'protected void onCreate(')
pin onCreate "$oc" "$READ"
before onCreate-guard "$oc" 'if (currentUser() != 0)' "$READ"
before onCreate-ring "$oc" 'new Thread(this::startRing' "$POST"
before onCreate-trace "$oc" "$POST" 'GateTrace.ev("ui-create")'

# stopRinging (Snooze, Dismiss, a volume press, onDestroy) cancels the timer.
pin stopRinging "$(method "$GAT" 'private void stopRinging(')" 'h.removeCallbacks(unattended);'

# The unattended Runnable: stopped first, then snooze with next(autoSoFar), or dismiss.
un=$(field "$GAT" 'private final Runnable unattended')
if [ -z "$un" ]; then
  echo "--- FAIL: pin: unattended: not found"; rc=1
else
  first=${un#*\{}; first="${first#"${first%%[![:space:]]*}"}"
  case "$first" in
    'if (stopped) return;'*) echo "--- PASS: pin: unattended checks stopped before anything else" ;;
    *) echo "--- FAIL: pin: unattended does not start with if (stopped) return;"; rc=1 ;;
  esac
  case "$un" in
    *'if (GateAlarmAuto.snoozes(autoSoFar)) {'*'} else {'*)
      sb=${un#*'if (GateAlarmAuto.snoozes(autoSoFar)) {'}; sb=${sb%%'} else {'*}
      db=${un#*'} else {'} ;;
    *) sb=""; db="" ;;
  esac
  pin unattended-snooze "$sb" 'GateTrace.ev("ui-auto-snooze");'
  pin unattended-snooze "$sb" 'stopRinging();'
  pin unattended-snooze "$sb" 'ChooserActivity.scheduleGateAlarmAt(getApplicationContext(), System.currentTimeMillis() + SNOOZE_MS, GateAlarmAuto.next(autoSoFar));'
  [ -n "$sb" ] && ends unattended-snooze "$sb" 'silenceSessionClock(this::finish);'
  pin unattended-dismiss "$db" 'GateTrace.ev("ui-auto-dismiss");'
  pin unattended-dismiss "$db" 'stopRinging();'
  pin unattended-dismiss "$db" 'ChooserActivity.cancelGateAlarm(getApplicationContext(), "cancel-dismiss");'
  pin unattended-dismiss "$db" 'silenceSessionClock(this::finish);'
fi

# The user's Snooze is attended: it re-arms through the two-argument form, which starts the count over.
pin snooze "$(method "$GAT" 'private void snooze(')" \
  'ChooserActivity.scheduleGateAlarmAt(getApplicationContext(), System.currentTimeMillis() + SNOOZE_MS);' 'GateAlarmAuto'

# The count rides alarm -> receiver -> activity.
pin GateAlarmReceiver.onReceive "$(method "$RCV" 'public void onReceive(')" \
  '.putExtra(GateAlarmAuto.EXTRA, GateAlarmAuto.sane(intent.getIntExtra(GateAlarmAuto.EXTRA, 0)))'
pin scheduleGateAlarmAt-3 "$(method "$ACT" 'static void scheduleGateAlarmAt(android.content.Context ctx, long when, int autoSnoozes)')" \
  'gateAlarmPi(ctx, autoSnoozes)'
pin scheduleGateAlarmAt-2 "$(method "$ACT" 'static void scheduleGateAlarmAt(android.content.Context ctx, long when) {')" \
  'scheduleGateAlarmAt(ctx, when, 0);' 'gateAlarmPi('
# tests/gate-alarm-verbs/run.sh reads the FIRST scheduleGateAlarmAt signature: it must be the one that arms.
pin scheduleGateAlarmAt-first "$(method "$ACT" 'static void scheduleGateAlarmAt(')" 'GateAlarmVerbs.arm('
gp=$(method "$ACT" 'private static android.app.PendingIntent gateAlarmPi(android.content.Context ctx, int autoSnoozes)')
pin gateAlarmPi "$gp" '.putExtra(GateAlarmAuto.EXTRA, GateAlarmAuto.sane(autoSnoozes))'
pin gateAlarmPi "$gp" 'FLAG_UPDATE_CURRENT'
pin gateAlarmPi-1 "$(method "$ACT" 'private static android.app.PendingIntent gateAlarmPi(android.content.Context ctx) {')" \
  'return gateAlarmPi(ctx, 0);'
pin cancelGateAlarm "$(method "$ACT" 'static void cancelGateAlarm(')" 'gateAlarmPi(ctx)'
# NWP-20261128-34: onCreate still lights the screen; a volume press silences the ring, THEN releases the screen-on hold.
pin onCreate-keep-screen-on "$oc" 'getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);'
dk=$(method "$GAT" 'public boolean dispatchKeyEvent(')
VOL='kc == KeyEvent.KEYCODE_VOLUME_MUTE) {'
DOWN='if (event.getAction() == KeyEvent.ACTION_DOWN) {'
case "$dk" in *"$VOL"*) vb=${dk#*"$VOL"}; vb=${vb%%'return super.dispatchKeyEvent'*} ;; *) vb="" ;; esac
case "$vb" in *"$DOWN"*) kb=${vb#*"$DOWN"}; kb=${kb%%'return true;'*} ;; *) kb="" ;; esac
if [ -z "$kb" ]; then
  echo "--- FAIL: pin: dispatchKeyEvent-down: no braced ACTION_DOWN branch in the volume branch"; rc=1
else
  before dispatchKeyEvent-down "$kb" 'stopRinging();' 'getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)'
fi
pin dispatchKeyEvent-volume "$vb" 'return true;'
exit "$rc"
