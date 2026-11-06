#!/usr/bin/env bash
# run.sh <GateAlarmVerbs.java> <ChooserActivity.java> <GateAlarmActivity.java> <gate_log.go> -- NWP-20261028-13: compile the
# REAL GateAlarmVerbs (unchanged), run GateAlarmVerbsCases, then pin the chooser call sites. $JAVAC / $JAVA come from
# core/chooser/test-gate-alarm-verbs-java.sh. Exit codes: 1 = a case or a pin failed; 3 = no compile, or the JVM died with anything but 0/1.
set -euo pipefail
SRC="${1:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go}"
ACT="${2:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go}"
GAT="${3:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go}"
GOL="${4:?usage: run.sh GateAlarmVerbs.java ChooserActivity.java GateAlarmActivity.java gate_log.go}"
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
pin scheduleGateAlarmFromDaemon "$(method "$ACT" 'private void scheduleGateAlarmFromDaemon(')" 'GateAlarmVerbs.consume('
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
before consume "$(method "$ACT" 'private void scheduleGateAlarmFromDaemon(')" 'scheduleGateAlarmAt(appCtx, when)' 'GateTrace.ev(v, "in"'
pin dismiss "$(method "$GAT" 'private void dismiss(')" 'cancelGateAlarm(getApplicationContext(), "cancel-dismiss")'
n=$(grep -c 'cancelGateAlarm(getApplicationContext(), "cancel-login")' "$ACT" || true)
if [ "$n" = 1 ]; then echo "--- PASS: pin: sign-in passes cancel-login"; else echo "--- FAIL: pin: ChooserActivity has $n cancel-login callers, want 1"; rc=1; fi
n=$(grep -c 'cancelGateAlarm(getApplicationContext(), "cancel-dismiss")' "$ACT" || true)
if [ "$n" = 0 ]; then echo "--- PASS: pin: sign-in does not pass cancel-dismiss"; else echo "--- FAIL: pin: ChooserActivity passes cancel-dismiss"; rc=1; fi
exit "$rc"
