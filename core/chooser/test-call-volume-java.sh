#!/usr/bin/env bash
# test-call-volume-java.sh [<CallVolume.java>] [--mutate] -- CallVolume.callStream, the stream the gate's call screen
# adjusts on a volume key, compiled UNCHANGED under javac and RUN (NWP-20261114-30).
#
# WHY THIS IS COMMITTED. IncomingCallActivity.dispatchKeyEvent adjusted STREAM_RING on every volume key, whatever the
# call's state. On an answered call at the gate, volume-up raised the next ring and the earpiece stayed where it was;
# volume-down on a loud speakerphone call lowered the next ring. The keys now adjust the call while the screen shows the
# call controls, and the ringer while it rings or with no call. The swallow (#99) stays. M4 below IS the pre-change line.
# What it does NOT prove: the handset run (answer a call at the gate, volume-up shows the call slider and the earpiece
# gets louder) -- dispatchKeyEvent's android behaviour is source-pinned only (the chooser cannot be compiled off the
# build host).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-call-volume-java.sh            # the cases and the pins
#   bash test-call-volume-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/CallVolume.java"
ACT="$HERE/src/com/nowhere/chooser/IncomingCallActivity.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/call-volume/run.sh"
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
for f in "$SRC" "$ACT" "$RUN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export CALL_VOLUME_TMP="$W"

# suite <CallVolume> <IncomingCallActivity> -> run.sh's code: 0 pass, 1 a case or pin failed (only this may convict),
# 3 no compile.
suite() { bash "$RUN" "$1" "$2"; }

echo "== $SRC"
out=$(suite "$SRC" "$ACT" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <kind: vol|act> <perl-expr>
  local d m rc o orig v a f; d=$(mktemp -d -p "$W")
  v="$SRC"; a="$ACT"
  case "$2" in
    vol) orig="$SRC"; f=CallVolume.java; m="$d/$f"; v="$m" ;;
    act) orig="$ACT"; f=IncomingCallActivity.java; m="$d/$f"; a="$m" ;;
    *) echo "  ERROR     $1 -- unknown mutant kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$v" "$a" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 callStream ignores outgoing (C5)" vol \
  's/return haveCall && \(outgoing \|\| !ringing\);/return haveCall && (!ringing);/' || fails=$((fails+1))
mut "M2 callStream ignores ringing (C2)" vol \
  's/return haveCall && \(outgoing \|\| !ringing\);/return haveCall && (outgoing || true);/' || fails=$((fails+1))
mut "M3 callStream always returns false (C3, C4)" vol \
  's/return haveCall && \(outgoing \|\| !ringing\);/return false;/' || fails=$((fails+1))
mut "M4 dispatchKeyEvent back to the hard-coded STREAM_RING (pin)" act \
  's/am\.adjustStreamVolume\(stream, dir,/am.adjustStreamVolume(android.media.AudioManager.STREAM_RING, dir,/' || fails=$((fails+1))
mut "M5 SIMULATED_RINGING dropped (pin)" act 's/ \|\| st == Call\.STATE_SIMULATED_RINGING//' || fails=$((fails+1))
mut "M6 the mute key reaches PhoneWindow again (pin)" act \
  's/\n\s*\|\| kc == KeyEvent\.KEYCODE_VOLUME_MUTE\) \{/) {/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
