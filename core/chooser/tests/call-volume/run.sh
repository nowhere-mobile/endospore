#!/usr/bin/env bash
# run.sh <CallVolume.java> <IncomingCallActivity.java> -- NWP-20261114-30: compile the REAL CallVolume (unchanged), run
# CallVolumeCases, then pin IncomingCallActivity.dispatchKeyEvent's body (comments dropped first, so prose cannot
# satisfy a pin). $JAVAC / $JAVA come from core/chooser/test-call-volume-java.sh.
# Exit codes: 1 = a case or a pin failed; 3 = the sources did not compile, or the JVM died with anything but 0/1.
set -euo pipefail
U="usage: run.sh CallVolume.java IncomingCallActivity.java"
SRC="${1:?$U}"
ACT="${2:?$U}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${CALL_VOLUME_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$SRC" "$D/src/com/nowhere/chooser/CallVolume.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" "$D/src/com/nowhere/chooser/CallVolume.java" "$here/CallVolumeCases.java" \
    2>"$D/javac.err" || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.CallVolumeCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# ---- Source pins on dispatchKeyEvent. They read a comment-free copy (string-literal aware).
strip_java() { perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gse' "$1"; }
strip_java "$ACT" > "$D/act.java"
MARK='public boolean dispatchKeyEvent(KeyEvent event) {'
n=$(grep -cF "$MARK" "$D/act.java" || true)
if [ "$n" != 1 ]; then echo "--- FAIL: pin: the dispatchKeyEvent marker occurs $n times, not once"; exit 1; fi
awk -v sig="$MARK" 'index($0, sig) {f=1} f{print} f&&/^    }$/{exit}' "$D/act.java" > "$D/body.txt"
body=$(cat "$D/body.txt")

pin() { # pin <name> <command...>: PASS when the command succeeds
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "--- PASS: pin: $name"; else echo "--- FAIL: pin: $name"; rc=1; fi
}
has() { case "$body" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
hasnt() { ! has "$1"; }

# Control: the extraction found the method that adjusts the volume.
pin "control: dispatchKeyEvent calls adjustStreamVolume(" has 'adjustStreamVolume('
pin "dispatchKeyEvent picks the stream through CallVolume.callStream(" has 'CallVolume.callStream('
pin "dispatchKeyEvent names STREAM_VOICE_CALL" has 'STREAM_VOICE_CALL'
pin "dispatchKeyEvent reads Call.STATE_RINGING" has 'Call.STATE_RINGING'
pin "dispatchKeyEvent reads Call.STATE_SIMULATED_RINGING" has 'Call.STATE_SIMULATED_RINGING'
pin "adjustStreamVolume takes the chosen stream" has 'adjustStreamVolume(stream, dir,'
pin "no hard-coded STREAM_RING adjust is left" hasnt 'adjustStreamVolume(android.media.AudioManager.STREAM_RING'

# The currentCall() read comes after the body's `try {` line, so a throw still degrades to the swallow.
try_ln=$(awk '/try \{$/ {print NR; exit}' "$D/body.txt")
call_ln=$(awk 'index($0, "NowhereInCallService.currentCall()") {print NR; exit}' "$D/body.txt")
if [ -n "$try_ln" ] && [ -n "$call_ln" ] && [ "$call_ln" -gt "$try_ln" ]; then
  echo "--- PASS: pin: currentCall() is read inside the try (line $call_ln > $try_ln)"
else
  echo "--- FAIL: pin: currentCall() is not read after the try { line (try='$try_ln' currentCall='$call_ln')"; rc=1
fi

# The keycode condition, from its `if (kc ==` line to the first line ending `{`, holds all three keys.
cond=$(awk '/if \(kc ==/ {f=1} f{print} f&&/\{$/{exit}' "$D/body.txt")
for k in KEYCODE_VOLUME_UP KEYCODE_VOLUME_DOWN KEYCODE_VOLUME_MUTE; do
  case "$cond" in
    *"KeyEvent.$k"*) echo "--- PASS: pin: the keycode condition holds $k" ;;
    *) echo "--- FAIL: pin: the keycode condition lacks $k"; rc=1 ;;
  esac
done
pin "dispatchKeyEvent consumes the keys (return true;)" has 'return true;'
exit "$rc"
