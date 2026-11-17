#!/usr/bin/env bash
# run.sh <GateAlarmVerbs.java> <ChooserActivity.java> <GateAlarmActivity.java> <gate_log.go> <GateAlarmReceiver.java> --
# NWP-20261028-13: compile the REAL GateAlarmVerbs (unchanged), run GateAlarmVerbsCases, then pin the chooser call sites
# (GateAlarmReceiver since NWP-20261204-07; the reap watcher's LOCK-arm re-read, P-g1..P-g5, since NWP-20261207-10). $JAVAC / $JAVA come from
# core/chooser/test-gate-alarm-verbs-java.sh. Exit codes: 1 = a case or a pin failed; 3 = no compile, or the JVM died with anything but 0/1.
set -euo pipefail
SRC="${1:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go GateAlarmReceiver.java}"
ACT="${2:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go GateAlarmReceiver.java}"
GAT="${3:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go GateAlarmReceiver.java}"
GOL="${4:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go GateAlarmReceiver.java}"
RCV="${5:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go GateAlarmReceiver.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${GATE_ALARM_VERBS_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$SRC" "$D/src/com/nowhere/chooser/GateAlarmVerbs.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" "$D/src/com/nowhere/chooser/GateAlarmVerbs.java" "$here/GateAlarmVerbsCases.java" \
    2>"$D/javac.err" || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.GateAlarmVerbsCases "$GOL" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# method <file> <literal signature>: the method's text, from its 4-space-indented signature to the next "    }" line.
method() { awk -v sig="$2" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$1"; }
# pin <name> <body> <must contain> [<must NOT contain>]
pin() {
  local name="$1" body="$2" has="$3" hasnt="${4:-}"
  if [ -z "$body" ]; then echo "--- FAIL: pin: $name: method not found"; rc=1; return; fi
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
pin silenceSessionClock "$(method "$GAT" 'private void silenceSessionClock(')" 'GateAlarmVerbs.silence(reply)' '"ui-silence-ok"'
pin scheduleGateAlarmFromDaemon "$(method "$ACT" 'static void scheduleGateAlarmFromDaemon(')" 'GateAlarmVerbs.consume('
pin scheduleGateAlarmAt "$(method "$ACT" 'static void scheduleGateAlarmAt(')" 'GateAlarmVerbs.arm('
pin cancelGateAlarm "$(method "$ACT" 'static void cancelGateAlarm(')" 'GateTrace.ev(why)'
pin startVibrate "$(method "$GAT" 'private void startVibrate(')" 'vibrateErr = true' 'GateTrace.'
pin currentUser "$(method "$GAT" 'private static int currentUser(')" 'guardErr = true' 'GateTrace.'
# Ordering (RF-001): a new trace is never in front of the user-visible work.
before() { # <name> <body> <first> <then>: <first> appears, and strictly before <then>
  local name="$1" body="$2" a="$3" b="$4" pa pb
  pa=${body%%"$a"*}; pb=${body%%"$b"*}
  case "$body" in *"$a"*) ;; *) echo "--- FAIL: order: $name lacks $a"; rc=1; return ;; esac
  case "$body" in *"$b"*) ;; *) echo "--- FAIL: order: $name lacks $b"; rc=1; return ;; esac
  if [ "${#pa}" -lt "${#pb}" ]; then echo "--- PASS: order: $name: $a before $b"; else echo "--- FAIL: order: $name: $a not before $b"; rc=1; fi
}
before onCreate "$(method "$GAT" 'protected void onCreate(')" 'new Thread(this::startRing' 'GateTrace.ev("ui-guard-err")'
before onCreate-vib "$(method "$GAT" 'protected void onCreate(')" 'new Thread(this::startRing' 'GateTrace.ev("ui-vibrate-err")'
before consume "$(method "$ACT" 'static void scheduleGateAlarmFromDaemon(')" 'scheduleGateAlarmAt(appCtx, when)' 'GateTrace.ev(v, "in"'
pin dismiss "$(method "$GAT" 'private void dismiss(')" 'cancelGateAlarm(getApplicationContext(), "cancel-dismiss")'
n=$(grep -c 'cancelGateAlarm(getApplicationContext(), "cancel-login")' "$ACT" || true)
if [ "$n" = 1 ]; then echo "--- PASS: pin: sign-in passes cancel-login"; else echo "--- FAIL: pin: ChooserActivity has $n cancel-login callers, want 1"; rc=1; fi
n=$(grep -c 'cancelGateAlarm(getApplicationContext(), "cancel-dismiss")' "$ACT" || true)
if [ "$n" = 0 ]; then echo "--- PASS: pin: sign-in does not pass cancel-dismiss"; else echo "--- FAIL: pin: ChooserActivity passes cancel-dismiss"; rc=1; fi
nocomment() { sed -e 's://.*$::'; }
# NWP-20261207-10: the gate reads its alarm stash again in the reap watcher's LOCK arm (comments dropped). The
# daemon publishes LOCK only after the at-lock relay ended, so a hand-switch or Q087 re-park cold lock still rings.
# count <text> <awk regex>: how many times the regex occurs.
count() { printf '%s\n' "$1" | awk -v s="$2" '{ n += gsub(s, "") } END { print n + 0 }'; }
# arm <body> <start> <end>: the text strictly between <start> and the next <end> (empty if either is missing).
arm() { local b="$1" s="$2" e="$3" t
  case "$b" in *"$s"*) ;; *) return 0 ;; esac; t=${b#*"$s"}
  case "$t" in *"$e"*) ;; *) return 0 ;; esac; printf '%s' "${t%%"$e"*}"; }
# P-g1: the read is sendDaemon's 90 s round trip, never pollDaemon's 5 s (the daemon may hold it up to 60 s).
pin P-g1 "$(method "$ACT" 'static void scheduleGateAlarmFromDaemon(' | nocomment)" 'DaemonSocket.roundTrip("GET-GATE-ALARM\n", 90000)' 'pollDaemon('
# P-g2: onResume still reads, once, with the application context.
n=$(count "$(method "$ACT" 'protected void onResume(' | nocomment)" 'scheduleGateAlarmFromDaemon\\(getApplicationContext\\(\\)\\)')
if [ "$n" = 1 ]; then echo "--- PASS: pin: P-g2 onResume reads the gate alarm once"; else echo "--- FAIL: pin: P-g2 onResume reads the gate alarm $n times, want 1"; rc=1; fi
# P-g3: the LOCK arm reads once, before main.post (not inside the doColdLock lambda).
rw=$(method "$ACT" 'static void ensureReapWatcher(' | nocomment)
lk=$(arm "$rw" 'reply.startsWith("LOCK ")' 'reply.startsWith("REARM ")')
if [ -z "$lk" ]; then echo "--- FAIL: pin: P-g3 the LOCK arm not found"; rc=1
else
  n=$(count "$lk" 'scheduleGateAlarmFromDaemon\\(app\\)')
  if [ "$n" = 1 ]; then echo "--- PASS: pin: P-g3 the LOCK arm reads the gate alarm once"; else echo "--- FAIL: pin: P-g3 the LOCK arm reads the gate alarm $n times, want 1"; rc=1; fi
  before P-g3 "$lk" 'scheduleGateAlarmFromDaemon(app)' 'main.post('
fi
# P-g4: neither the SWITCH arm (the relay has not run yet) nor the REAP arm reads.
sw=$(arm "$rw" 'reply.startsWith("SWITCH ")' 'reply.startsWith("REAP ")')
rp=$(arm "$rw" 'reply.startsWith("REAP ")' 'reply.startsWith("LOCK ")')
for a in SWITCH:"$sw" REAP:"$rp"; do
  if [ "${a#*:}" = "" ]; then echo "--- FAIL: pin: P-g4 the ${a%%:*} arm not found"; rc=1; continue; fi
  n=$(count "${a#*:}" 'scheduleGateAlarmFromDaemon\\(')
  if [ "$n" = 0 ]; then echo "--- PASS: pin: P-g4 the ${a%%:*} arm does not read the gate alarm"; else echo "--- FAIL: pin: P-g4 the ${a%%:*} arm reads the gate alarm $n times, want 0"; rc=1; fi
done
# P-g5: one declaration and exactly two calls (onResume, the LOCK arm) in all of ChooserActivity.
all=$(nocomment < "$ACT")
d=$(count "$all" 'static void scheduleGateAlarmFromDaemon\\(')
n=$(count "$all" 'scheduleGateAlarmFromDaemon\\(')
if [ "$d" = 1 ] && [ "$n" = 3 ]; then echo "--- PASS: pin: P-g5 one declaration and two calls"
else echo "--- FAIL: pin: P-g5 $d static declaration(s) and $n occurrence(s) in all, want 1 and 3"; rc=1; fi
# NWP-20261204-07: the roamed-state trace at a gate-alarm fire (comments dropped).
ro=$(method "$RCV" 'public void onReceive(' | nocomment)
tr=$(method "$RCV" 'private static void traceRoamed(' | nocomment)
# P-a: the launch, then "fired", then the roamed trace.
before P-a-launch "$ro" 'ctx.startActivity(' 'GateTrace.ev("fired")'
before P-a-fired "$ro" 'GateTrace.ev("fired")' 'traceRoamed(app)'
# P-b: the enumeration runs only inside the new thread.
pin P-b "$ro" 'new Thread(() -> traceRoamed(app), "nowhere-gate-roamed").start();' 'getSecondaryUsers('
n=$(printf '%s\n' "$ro" | awk '{ n += gsub(/traceRoamed\(/, "") } END { print n + 0 }')
if [ "$n" = 1 ]; then echo "--- PASS: pin: P-b onReceive calls traceRoamed once, in the thread"; else echo "--- FAIL: pin: P-b onReceive calls traceRoamed $n times, want 1"; rc=1; fi
# P-c: isUserRunning is the only running test, the helper sends what roamed() returns, and it logs nothing.
pin P-c-running "$tr" 'um.isUserRunning(uh)' 'isUserUnlocked'
pin P-c-foreground "$tr" 'GateTrace.ev(GateAlarmVerbs.roamed(secondary, running, false))' 'isUserForeground'
pin P-c-nolog "$tr" 'dpm.getSecondaryUsers(admin)' 'android.util.Log'
exit "$rc"
