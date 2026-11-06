#!/usr/bin/env bash
# test-idle-lock-gate-java.sh [--mutate] -- NWP-20261021-02: the idle cold lock's whole pre-commit decision (the
# at-rest security bound's screen-on, late-fire, in-call and installs defers, and since NWP-20261120-02 the audio wait).
# Runs core/chooser/tests/idle-lock-gate: the chooser's pure IdleLockGate, compiled against its cases ALONE and EXECUTED.
# Two pins read the receiver's playback check and ChooserActivity's screen-off reset of the audio hold.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of IdleLockGate.java, each of which must FAIL a named case. A mutant
# that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-idle-lock-gate-java.sh            # the cases
#   bash test-idle-lock-gate-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-idle-lock-gate-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the traps remove it however this ends.
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/idle-lock-gate/run.sh" "$1" "$(mktemp -d -p "$W")"; }
RECV=$CH/IdleLogoffReceiver.java
CHOOSER=$CH/ChooserActivity.java
AGENT_MAIN=core/agent/main.go
# pin_receiver <file>: the receiver reads the daemon's reply ONLY through IdleLockGate.afterReply, in the worker's
# finally -- the block that follows the worker's try/catch, so a finally turned into dead code fails -- and acts on its
# two fields. `//` comment lines are dropped first, so a comment cannot satisfy or trip it.
pin_receiver() {
  local f=$1 code
  code=$(grep -vE '^[[:space:]]*//' "$f") || true
  if ! perl -0e '
    my $c = do { local $/; <STDIN> };
    my $n = () = $c =~ /IdleLockGate\.afterReply\(replyRef\.get\(\)\)/g;
    exit 1 unless $n == 1;
    exit 1 unless $c =~ /Thread worker = new Thread\(\(\) -> \{.*?\} finally \{\s*try \{ s\.close\(\); \} catch \(Throwable ignore\) \{\}\s*IdleLockGate\.AfterReply after = IdleLockGate\.afterReply\(replyRef\.get\(\)\);(?<body>.*?)finish\.run\(\);\s*\}\s*\}\);\s*worker\.setDaemon/s;
    my $body = $+{body};
    my $r = () = $c =~ /rearmIdleShort\(ctx, NOLOCK_REGRACE_MS\)/g;
    my $rb = () = $body =~ /rearmIdleShort\(ctx, NOLOCK_REGRACE_MS\)/g;
    exit 1 unless $r == 1 && $rb == 1 && $body =~ /if \(after\.rearm\) \{[^}]*rearmIdleShort\(ctx, NOLOCK_REGRACE_MS\);/s;
    my $w = () = $c =~ /coldWakeRelease\(\)/g;
    my $wb = () = $body =~ /coldWakeRelease\(\)/g;
    exit 1 unless $w == 1 && $wb == 1 && $body =~ /if \(after\.releaseWake\) \{\s*ChooserActivity\.coldWakeRelease\(\);/s;
    exit 1 if $c =~ /\.contains\("LOCKING"\)|\.contains\("NOSESSION"\)|AtomicBoolean locking/;
    exit 0;' <<<"$code"; then
    echo "FAIL receiver-afterReply: $f no longer reads the daemon's reply only through IdleLockGate.afterReply(replyRef.get()) as the worker's own `} finally {` block (socket close, verdict, then finish.run()), with the re-arm under if (after.rearm) and coldWakeRelease() under if (after.releaseWake)"
    return 1
  fi
  echo "ok receiver-afterReply"
}
# pin_audio_receiver <file>: NWP-20261120-02. The playback check sits in a try whose catch (Throwable) sets the input
# to null (a failed check proceeds to the lock), the verdict's audioHolding is written back once, and AUDIO_HELD and
# AUDIO_STOPPED re-arm with the verdict's delay and return. `//` comment lines are dropped first.
pin_audio_receiver() {
  local f=$1 code
  code=$(grep -vE '^[[:space:]]*//' "$f") || true
  if ! perl -0e '
    my $c = do { local $/; <STDIN> };
    my $n = () = $c =~ /getActivePlaybackConfigurations\(\)/g;
    exit 1 unless $n == 1;
    exit 1 unless $c =~ /try \{(?:(?!\} catch).)*?getActivePlaybackConfigurations\(\)(?:(?!\} catch).)*?\} catch \(Throwable \w+\) \{[^}]*?audioPlaying = null;/s;
    my $w = () = $c =~ /ChooserActivity\.sAudioHolding = v\.audioHolding;/g;
    exit 1 unless $w == 1;
    for my $x ("AUDIO_HELD", "AUDIO_STOPPED") {
      exit 1 unless $c =~ /case \Q$x\E:(?:(?!case ).)*?ChooserActivity\.rearmIdleShort\(ctx, v\.delayMs\);\s*return;/s;
    }
    exit 0;' <<<"$code"; then
    echo "FAIL receiver-audio: $f no longer reads getActivePlaybackConfigurations() once, inside a try whose catch (Throwable) sets audioPlaying = null, writes ChooserActivity.sAudioHolding = v.audioHolding; once, and re-arms with rearmIdleShort(ctx, v.delayMs) then returns on AUDIO_HELD and AUDIO_STOPPED"
    return 1
  fi
  echo "ok receiver-audio"
}
# pin_idle_reset <ChooserActivity.java>: NWP-20261120-02. armIdleWatcher's screen-off arm clears the audio hold on the
# statement right after it clears the hold start, so no audio hold carries into a fresh idle cycle. The anchor is the
# arm itself: the declaration of sAudioHolding cannot satisfy it.
pin_idle_reset() {
  local f=$1 code
  code=$(grep -vE '^[[:space:]]*//' "$f") || true
  if ! perl -0e '
    my $c = do { local $/; <STDIN> };
    exit 1 unless $c =~ /sIdleLateGrace\.set\(false\);[^\n]*\n\s*sHeldForInstallsSince = 0L;[^\n]*\n\s*sAudioHolding = false;/;
    exit 0;' <<<"$code"; then
    echo "FAIL idle-reset: $f no longer clears sAudioHolding on the statement after sHeldForInstallsSince = 0L; in armIdleWatcher's screen-off arm"
    return 1
  fi
  echo "ok idle-reset"
}
# check_tokens <main.go>: every reply handleColdLock writes is one of the three tokens afterReply knows. A new token
# fails by name: the chooser has to be taught it first.
check_tokens() {
  local f=$1 body toks t n seen=""
  body=$(awk '/^func handleColdLock\(/{p=1} p{print} p&&/^}/{exit}' "$f")
  toks=$(grep -oE 'fmt\.Fprint\(conn, "[^"]*\\n"\)' <<<"$body" | sed -E 's/^fmt\.Fprint\(conn, "(.*)\\n"\)$/\1/')
  n=$(grep -c . <<<"$toks")
  if [ "$n" -lt 3 ]; then echo "FAIL daemon-reply-tokens: only $n replies found in handleColdLock of $f (at least 3 expected)"; return 1; fi
  while IFS= read -r t; do
    case "$t" in
      "OK LOCKING"|"OK NOSESSION"|"OK LOGOFF") ;;
      *) echo "FAIL daemon-reply-tokens: handleColdLock sends \"$t\", which IdleLockGate.afterReply does not know"; return 1 ;;
    esac
  done <<<"$toks"
  for t in "OK LOCKING" "OK NOSESSION" "OK LOGOFF"; do
    grep -qxF -- "$t" <<<"$toks" || { echo "FAIL daemon-reply-tokens: handleColdLock no longer sends \"$t\""; return 1; }
  done
  echo "ok daemon-reply-tokens ($n replies)"
}
run "$ROOT" || { echo "FAILED"; exit 1; }
pin_receiver "$ROOT/$RECV" || { echo "FAILED"; exit 1; }
pin_audio_receiver "$ROOT/$RECV" || { echo "FAILED"; exit 1; }
pin_idle_reset "$ROOT/$CHOOSER" || { echo "FAILED"; exit 1; }
check_tokens "$ROOT/$AGENT_MAIN" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr over IdleLockGate.java> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  f="$d/$CH/IdleLockGate.java"
  cp "$ROOT/$CH/IdleLockGate.java" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/IdleLockGate.java" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
smut() { # smut <label> <file under ROOT> <perl-expr> <pin_*|check_tokens> <FAIL label the check must print>
  local d f out rc
  d=$(mktemp -d -p "$W")
  f="$d/$(basename "$2")"
  cp "$ROOT/$2" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$("$4" "$f" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $5" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$5' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$5')"
}
fails=0
mut "M1 the screen-on guard deleted" 's/if \(screenOn\) \{/if (false) {/' \
  "screen on -> defer 60s, claim not called" || fails=$((fails+1))
mut "M2 late threshold > becomes >=" 's/lateByMs > LATE_FIRE_MS/lateByMs >= LATE_FIRE_MS/' \
  "lateBy 2000 is on time: no claim, LOCK" || fails=$((fails+1))
mut "M3 the claim moved before the screen-on guard" 's/(        if \(screenOn\) \{)/        boolean early = claimLateGrace.getAsBoolean();\n$1/; s/lateByMs > LATE_FIRE_MS && claimLateGrace\.getAsBoolean\(\)/lateByMs > LATE_FIRE_MS \&\& early/' \
  "screen on -> defer 60s, claim not called" || fails=$((fails+1))
mut "M4 the claim evaluated before the threshold" 's/lateByMs > LATE_FIRE_MS && claimLateGrace\.getAsBoolean\(\)/claimLateGrace.getAsBoolean() \&\& lateByMs > LATE_FIRE_MS/' \
  "lateBy 2000 is on time: no claim, LOCK" || fails=$((fails+1))
mut "M5 a failed call check treated as in a call" 's/Boolean\.TRUE\.equals\(inCall\)/!Boolean.FALSE.equals(inCall)/' \
  "inCall null proceeds -> LOCK" || fails=$((fails+1))
mut "M6 startsWith(LIVE) replaced by a non-empty test" 's/r\.startsWith\("LIVE"\)/!r.isEmpty()/' \
  "sweep \"ERR\" -> LOCK" || fails=$((fails+1))
mut "M7 cap comparison < becomes <=" 's/held < capMs/held <= capMs/' \
  "held 60 min -> LOCK cap reached" || fails=$((fails+1))
mut "M8 the cap check deleted" 's/held < capMs/true/' \
  "held 60 min -> LOCK cap reached" || fails=$((fails+1))
mut "M9 the holdForInstalls flag ignored" 's/if \(holdForInstalls\) \{/if (true) {/' \
  "hold off -> LOCK, sweep never called" || fails=$((fails+1))
mut "M10 the hold start stamp inverted" 's/heldSinceMs == 0L \? now/heldSinceMs != 0L ? now/' \
  "LIVE, first hold -> defer 5 min, stamped now" || fails=$((fails+1))
mut "M11 the clock read before the sweep" 's/(            String r = sweepReply\.get\(\);)/            long early = nowMs.getAsLong();\n$1/; s/long now = nowMs\.getAsLong\(\);/long now = early;/' \
  "clock crosses the cap during the sweep -> LOCK" || fails=$((fails+1))
mut "A1 the holdForAudio flag ignored" 's/if \(holdForAudio\) \{/if (true) {/' \
  "audio hold off ignores playing" || fails=$((fails+1))
mut "A2 audio cap < becomes <=" 's/audioHeld < audioCapMs/audioHeld <= audioCapMs/' \
  "audio at the 120 min cap, sweep not LIVE -> AUDIO_CAP" || fails=$((fails+1))
mut "A3 the audio cap check deleted" 's/audioHeld < audioCapMs/true/' \
  "audio at the 120 min cap, sweep not LIVE -> AUDIO_CAP" || fails=$((fails+1))
mut "A4 a failed audio check read as playing" 's/Boolean\.TRUE\.equals\(audioPlaying\)/!Boolean.FALSE.equals(audioPlaying)/' \
  "audio check failed (null) -> LOCK" || fails=$((fails+1))
mut "A5 the AUDIO_STOPPED arm deleted" 's/Boolean\.FALSE\.equals\(audioPlaying\) && audioHolding/false/' \
  "audio stopped after a hold -> restart standby" || fails=$((fails+1))
mut "A6 AUDIO_STOPPED waits 60s, not the standby" 's/Reason\.AUDIO_STOPPED, standbyMs,/Reason.AUDIO_STOPPED, AUDIO_DEFER_MS,/' \
  "audio stopped after a hold -> restart standby" || fails=$((fails+1))
mut "A7 installs takes its own start" 's/long hs = heldSinceMs == 0L \? now : heldSinceMs;/long hs = now;/' \
  "installs counts from an earlier audio hold's start" || fails=$((fails+1))
mut "A8 countsAsAudio counts a paused player" 's/return started && mediaUsage/return mediaUsage/' \
  "countsAsAudio paused media uid -1 -> false" || fails=$((fails+1))
mut "A9 countsAsAudio counts a user-0 uid" 's/clientUid \/ PER_USER_RANGE != 0/true/' \
  "countsAsAudio started media uid 10123 (user 0) -> false" || fails=$((fails+1))
mut "R1 locking = startsWith(OK)" 's/"OK LOCKING"\.equals\(t\)/t.startsWith("OK")/' \
  'afterReply "OK LOGOFF" -> rearm=true release=false' || fails=$((fails+1))
mut "R2 releaseWake = rearm" 's/new AfterReply\(!locking, nothingToLock\)/new AfterReply(!locking, !locking)/' \
  'afterReply "OK LOGOFF" -> rearm=true release=false' || fails=$((fails+1))
mut "R3 nothingToLock = contains(NOSESSION)" 's/"OK NOSESSION"\.equals\(t\)/t.contains("NOSESSION")/' \
  'afterReply "ERR-NOSESSION" -> rearm=true release=false' || fails=$((fails+1))
mut "R4 the trim dropped" 's/reply\.trim\(\)/reply/' \
  'afterReply " OK LOCKING " -> rearm=false release=false' || fails=$((fails+1))
smut "R5 re-arm inverted" "$RECV" 's/if \(after\.rearm\) \{/if (!after.rearm) {/' pin_receiver receiver-afterReply || fails=$((fails+1))
smut "R6 wakelock released on rearm" "$RECV" 's/if \(after\.releaseWake\) \{/if (after.rearm) {/' pin_receiver receiver-afterReply || fails=$((fails+1))
smut "R7 daemon sends an unknown token" "$AGENT_MAIN" 's/(func handleColdLock\([^\n]*\n)/$1\tfmt.Fprint(conn, "OK QUEUED\\n")\n/' check_tokens daemon-reply-tokens || fails=$((fails+1))
smut "R8 the worker's finally made dead code" "$RECV" 's/\} finally \{/} if (false) {/' pin_receiver receiver-afterReply || fails=$((fails+1))
smut "R9 the worker's finally turned into a catch" "$RECV" 's/\} finally \{/} catch (RuntimeException unreached) {/' pin_receiver receiver-afterReply || fails=$((fails+1))
smut "S1 the playback check's Throwable catch removed" "$RECV" 's/\} catch \(Throwable \w+\) \{[^}]*?audioPlaying = null;\s*\}/} finally {}/' pin_audio_receiver receiver-audio || fails=$((fails+1))
smut "S2 the sAudioHolding write-back removed" "$RECV" 's/[ \t]*ChooserActivity\.sAudioHolding = v\.audioHolding;\n//' pin_audio_receiver receiver-audio || fails=$((fails+1))
smut "S3 the screen-off reset removed" "$CHOOSER" 's/(sHeldForInstallsSince = 0L; \/\/ NWP-20261005-02[^\n]*)\n[ \t]*sAudioHolding = false;[^\n]*/$1/' pin_idle_reset idle-reset || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
