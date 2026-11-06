#!/usr/bin/env bash
# test-gate-ecb-second-java.sh [--mutate] -- NWP-20261114-02 (Q044): an emergency callback that arrives as a SECOND
# concurrent inbound call at the gate takes the line. Runs core/chooser/tests/gate-ecb-second (secondCall and its three
# constants, lifted, compiled and EXECUTED), then pins the android side of NowhereInCallService that javac cannot reach
# off the build host: adoptIncoming, callIsEmergency, handOver, answer, declineOrHangup and onCallRemoved.
#
# WHY THIS IS COMMITTED. The gate is a single line with no call-waiting UI, so adoptIncoming rejected every second
# inbound call. An ordinary call ringing at the gate then pushed a PSAP's callback off the line and filed it as missed.
# Q044 (docs/product-decisions.md, 2026-10-20): the second call takes the line only when ITS OWN details mark it as an
# emergency call and the call on screen's do not; a ringing first call is rejected, an answered one ends when the
# callback is answered; the callback-mode flags and the 15-minute window are never used here. Each part is one line a
# later edit can drop with no build break, and the screen (IncomingCallActivity) finishes on any DISCONNECTED it is
# sent, so the order of the hand-over matters as much as the decision.
#
# It needs a JDK, and it FAILS (exit 2) when there is none: a Java suite that skips would read green on a runner that
# never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. --mutate re-runs the cases and pins
# against deliberately broken copies, each of which must fail a CASE or a PIN (a copy that no longer extracts or
# compiles convicts nothing and is reported).
#
# The scope guard (NowhereCallControlService.java and IncomingCallActivity.java byte-identical to the base ref,
# ${NOWHERE_BASE_REF:-origin/main}) needs that ref. CI checks out the pushed commit alone, so there it is reported as not
# checked, never as a pass.
#
#   bash test-gate-ecb-second-java.sh            # the cases and the pins
#   bash test-gate-ecb-second-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/gate-ecb-second/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-gate-ecb-second-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-gate-ecb-second-java: FAIL -- the pins need perl, and there is none" >&2; exit 2; }
export JAVAC JAVA
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

# strip <file>: the source with every /* */ and // comment removed (string literals kept), so a pin never matches a
# comment.
strip() {
  perl -0pe 's{("(?:\\.|[^"\\])*")|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gse' "$1"
}
# body <stripped file> <declaration>: from the line holding the declaration to the brace closing it.
body() {
  awk -v a="$2" '
    !on && index($0, a) { on=1; depth=0 }
    on { print; n=gsub(/[{]/,"{"); c=gsub(/[}]/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
# has <text> <needle>: the text contains the needle (fixed string).
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# before <text> <a> <b>: both occur, and the first a comes before the first b.
before() {
  local t="$1" a="$2" b="$3" pa pb
  has "$t" "$a" && has "$t" "$b" || return 1
  pa=${t%%"$a"*}; pb=${t%%"$b"*}
  [ "${#pa}" -lt "${#pb}" ]
}
# rx <text> <ERE>: the text matches the extended regular expression.
rx() { [[ $1 =~ $2 ]]; }
# between <text> <from> <to>: the text from the first <from> up to the next <to> after it.
between() {
  local t="$1" r
  has "$t" "$2" || return 0
  r=${t#*"$2"}
  printf '%s' "${r%%"$3"*}"
}

FAILS=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; FAILS=$((FAILS+1)); }
chk() { local label="$1"; shift; if "$@"; then ok "$label"; else no "$label"; fi; }

# pins <chooser dir>: the source pins; sets FAILS.
pins() {
  local src="$1/src/com/nowhere/chooser/NowhereInCallService.java" s ai ce ho an dh cr take
  [ -f "$src" ] || { echo "  no such file: $src" >&2; return 2; }
  s=$(mktemp -p "$W")
  strip "$src" > "$s"
  ai=$(body "$s" 'private void adoptIncoming(Call call)')
  ce=$(body "$s" 'static boolean callIsEmergency(Context app, Call.Details d)')
  ho=$(body "$s" 'private void handOver(Call next)')
  an=$(body "$s" 'static void answer()')
  dh=$(body "$s" 'static void declineOrHangup()')
  cr=$(body "$s" 'public void onCallRemoved(Call call)')
  take=$(between "$ai" 'act == TAKE_REJECT_CURRENT' 'act == TAKE_END_ON_ANSWER')

  chk "P1 adoptIncoming decides a second call by secondCall, and still rejects the new call on REJECT_NEW" \
    eval 'has "$ai" "secondCall(" && has "$ai" "call.reject(false, null)" && has "$ai" "else call.disconnect()"'
  chk "P2 callIsEmergency reads the network's emergency flag and the emergency-number test" \
    eval 'has "$ce" "PROPERTY_NETWORK_IDENTIFIED_EMERGENCY_CALL" && has "$ce" "isEmergencyNumber("'
  chk "P3 callIsEmergency never reads callback mode, the window or emergencyExemption (Q044)" \
    eval '[ -n "$ce" ] && ! has "$ce" PROPERTY_EMERGENCY_CALLBACK_MODE && ! has "$ce" getEmergencyCallbackMode \
          && ! has "$ce" sLastEmergencyOutboundAt && ! has "$ce" emergencyExemption && ! grep -q emergencyExemption "$s"'
  chk "P4 handOver takes uiForward off the old call before it moves current" \
    eval 'before "$ho" "old.unregisterCallback(uiForward)" "current = next;"'
  chk "P5 handOver repaints the bound screen with the new call's state" \
    eval 'has "$ho" "st = next.getState()" && has "$ho" "l.onCallState(st)" && has "$ho" "next.registerCallback(uiForward)"'
  chk "P6 no handOver path sends DISCONNECTED or DISCONNECTING to the screen" \
    eval '[ -n "$ho" ] && ! rx "$ho" "onCallState[(][[:space:]]*Call[.]STATE_DISCONNECT" \
          && has "$ho" "st != Call.STATE_DISCONNECTED && st != Call.STATE_DISCONNECTING"'
  chk "P7 TAKE_REJECT_CURRENT hands the screen over before it rejects the old call" \
    eval 'has "$take" "Call old = current;" && before "$take" "handOver(call)" "old.reject(false, null)"'
  chk "P8 TAKE_END_ON_ANSWER keeps the answered call as pendingEnd and hands the screen over" \
    eval 'before "$(between "$ai" "act == TAKE_END_ON_ANSWER" "else {")" "pendingEnd = current;" "handOver(call)"'
  chk "P9 answer() ends pendingEnd before it answers the callback" \
    eval 'before "$an" "= s.pendingEnd;" "end.disconnect()" && before "$an" "end.disconnect()" ".answer(VideoProfile"'
  chk "P10 declineOrHangup hands the screen back to pendingEnd before it rejects the callback" \
    eval 'before "$dh" "= s.pendingEnd;" "s.handOver(back)" && before "$dh" "s.handOver(back)" ".reject("'
  chk "P11 onCallRemoved clears a removed pendingEnd" \
    eval 'has "$cr" "if (call == pendingEnd) {"'
  chk "P12 onCallRemoved restores pendingEnd through handOver" \
    eval 'before "$cr" "Call back = pendingEnd;" "handOver(back)"'
  chk "P13 onCallRemoved sends DISCONNECTED only after the pendingEnd restore" \
    eval 'before "$cr" "handOver(back)" "onCallState(Call.STATE_DISCONNECTED)"'
  return 0
}

echo "== cases: $CH"
bash "$RUN" "$CH"; rc=$?
# The JDK was found above, so a 2 or 3 here is the source: secondCall or a constant missing, or not compiling.
case "$rc" in 0) ;; 1) FAILS=$((FAILS+1)) ;; *) no "the cases: secondCall and its constants do not lift or compile (rc=$rc)" ;; esac
echo "== pins"
pins "$CH" || exit 2
BASE="${NOWHERE_BASE_REF:-origin/main}"
if git -C "$ROOT" rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1; then
  for f in NowhereCallControlService.java IncomingCallActivity.java; do
    p="core/chooser/src/com/nowhere/chooser/$f"
    b=$(mktemp -p "$W")
    if git -C "$ROOT" show "$BASE:$p" > "$b" 2>/dev/null && cmp -s "$b" "$ROOT/$p"; then
      ok "S $f is byte-identical to $BASE"
    else
      no "S $f is byte-identical to $BASE"
    fi
  done
else
  echo "  note: $BASE absent (shallow checkout); the scope guard S is not checked"
fi
[ "$FAILS" -eq 0 ] || { echo "FAILED ($FAILS)"; exit 1; }
echo "all cases and pins passed"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by a case or a pin: a mutant that does not extract or compile proves nothing)"
I=src/com/nowhere/chooser/NowhereInCallService.java
mut() { # mut <label> <perl-expr>
  local rc out f="$W/m/$I"
  rm -rf "$W/m"; mkdir -p "$W/m/src/com/nowhere/chooser"
  cp "$CH"/src/com/nowhere/chooser/*.java "$W/m/src/com/nowhere/chooser/"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$f" "$CH/$I"; then echo "  INERT     $1"; return 1; fi
  bash "$RUN" "$W/m" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    out=$(pins "$W/m") || rc=2 # a subshell: its FAIL lines, not FAILS, say whether a pin failed
    [ "$rc" -eq 0 ] && case "$out" in *"  FAIL "*) rc=1 ;; esac
  fi
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 TAKE when both calls are emergency"            's/if \(!incomingIsEmergency \|\| currentIsEmergency\) return REJECT_NEW;/if (!incomingIsEmergency) return REJECT_NEW;/' || fails=$((fails+1))
mut "M2 TAKE_REJECT_CURRENT for an answered current"   's/return currentRinging \? TAKE_REJECT_CURRENT : TAKE_END_ON_ANSWER;/return TAKE_REJECT_CURRENT;/' || fails=$((fails+1))
mut "M3 callIsEmergency also reads callback mode"      's/(        \} catch \(Throwable ignore\) \{\}\n        try \{\n            String from = numberOf\(d\);)/        } catch (Throwable ignore) {}\n        try {\n            if (d != null && d.hasProperty(Call.Details.PROPERTY_EMERGENCY_CALLBACK_MODE)) return true;\n$1/' || fails=$((fails+1))
mut "M4 answer() does not end pendingEnd"              's/try \{ end\.disconnect\(\); \} catch \(Throwable ignore\) \{\}//' || fails=$((fails+1))
mut "M5 the REJECT_NEW branch removed"                 's/                    if \(call\.getState\(\) == Call\.STATE_RINGING\) call\.reject\(false, null\);\n                    else call\.disconnect\(\);\n//' || fails=$((fails+1))
mut "M6 handOver without the repaint"                  's/if \(st != Call\.STATE_DISCONNECTED && st != Call\.STATE_DISCONNECTING\) l\.onCallState\(st\);//' || fails=$((fails+1))
mut "M7 handOver leaves uiForward on the old call"     's/        if \(old != null\) \{ try \{ old\.unregisterCallback\(uiForward\); \} catch \(Throwable ignore\) \{\} \}\n//' || fails=$((fails+1))
mut "M8 onCallRemoved sends DISCONNECTED while pendingEnd is live" 's/(            if \(live\) \{\n)(                handOver\(back\);)/$1                { UiListener l0 = ui; if (l0 != null) l0.onCallState(Call.STATE_DISCONNECTED); }\n$2/' || fails=$((fails+1))
mut "M9 declineOrHangup rejects before it hands over"  's/(                s\.handOver\(back\);\n)(                cb\.reject\(false, null\);\n)/$2$1/' || fails=$((fails+1))
mut "M10 the old call rejected before the hand-over"   's/(                handOver\(call\);\n)(                try \{ old\.reject\(false, null\); \} catch \(Throwable ignore\) \{\}\n)/$2$1/' || fails=$((fails+1))
mut "M11 onCallRemoved never restores pendingEnd"      's/            if \(live\) \{\n                handOver\(back\);\n            \} else \{/            {/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
