#!/usr/bin/env bash
# test-media-ring-relay-java.sh [--mutate] -- the media ring poller's send decision, run under javac (NWP-20261128-19).
#
# WHY THIS IS COMMITTED. Backlog row "An app's blue media ring stays on its home-screen icon with no media notice".
# The launcher patch (launcher3-media-progress-ring.sh, trebuchet-media-progress-ring.sh) registers its MEDIA_PROGRESS
# receiver in Launcher.onResume, unregisters it in onPause, and keeps the last map in a static field.
# ChooserActivity.startMediaRingPoller used to broadcast ONLY on a change. A prefetch that ended while an app was in
# front sent its clear to no receiver, the poller never sent it again, and back home the launcher drew the stale ring
# (the reap watcher's notice reads the daemon itself, so it cleared: a ring with no notice). MediaRingRelay (pure,
# java.lang only) re-sends an unchanged value every RESEND_MS, the empty clear included; it is compiled here with its
# cases. A pin over startMediaRingPoller's body requires the poller to send through the relay.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-media-ring-relay-java.sh            # the cases and the pin
#   bash test-media-ring-relay-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/MediaRingRelay.java"
CHOOSER="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/media-ring-relay/MediaRingRelayCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <MediaRingRelay.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  MediaRingRelay.java does not exist (the send decision is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/MediaRingRelay.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/MediaRingRelayCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.MediaRingRelayCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# pin <ChooserActivity.java> -> 0 when startMediaRingPoller sends through MediaRingRelay, 1 otherwise.
# Comment lines are blanked and trailing ` // ...` text cut first, so a comment naming a call does not satisfy the pin.
# The body runs from the method's signature to its closing `    }` (four spaces, the method indent).
pin() {
  local f="$1" body x nd nb ns bad=0
  body=$(awk '{ if ($0 ~ /^[ \t]*(\/\/|\*|\/\*)/) print ""; else { sub(/[ \t]\/\/.*$/, ""); print } }' "$f" \
    | awk '/private void startMediaRingPoller\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }')
  [ -n "$body" ] || { echo "  FAIL  pin: no private void startMediaRingPoller() in $f" >&2; return 1; }
  for x in 'final MediaRingRelay relay = new MediaRingRelay();' 'if (uid < 0) { relay.reset(); continue; }' \
           'long now = android.os.SystemClock.elapsedRealtime();' 'if (!relay.due(prog, uid, now)) continue;' \
           'relay.sent(prog, uid, now);'; do
    case "$body" in *"$x"*) ;; *) echo "  FAIL  pin: startMediaRingPoller lacks: $x" >&2; bad=1 ;; esac
  done
  for x in 'prog.equals(last)' 'lastUid'; do
    case "$body" in *"$x"*) echo "  FAIL  pin: startMediaRingPoller still holds the change-only test ($x)" >&2; bad=1 ;; esac
  done
  # The send is recorded only after a broadcast that did not throw: sent() follows sendBroadcast, before the catch.
  nd=$(printf '%s\n' "$body" | awk '/relay\.due\(/ { print NR; exit }')
  nb=$(printf '%s\n' "$body" | awk '/\.sendBroadcast\(mpi\);/ { print NR; exit }')
  ns=$(printf '%s\n' "$body" | awk '/relay\.sent\(/ { print NR; exit }')
  x=$(printf '%s\n' "$body" | awk '/relay\.sent\(/ { n++ } END { print n + 0 }')
  [ "$x" -eq 1 ] || { echo "  FAIL  pin: relay.sent is called $x time(s), want 1" >&2; bad=1; }
  if [ -z "$nd" ] || [ -z "$nb" ] || [ -z "$ns" ]; then
    echo "  FAIL  pin: the due test, the broadcast or the sent record is missing" >&2; bad=1
  elif ! { [ "$nd" -lt "$nb" ] && [ "$nb" -lt "$ns" ]; }; then
    echo "  FAIL  pin: want due ($nd) < sendBroadcast ($nb) < sent ($ns)" >&2; bad=1
  else
    x=$(printf '%s\n' "$body" | awk -v s="$nb" -v e="$ns" 'NR > s && NR <= e && /catch/ { n++ } END { print n + 0 }')
    [ "$x" -eq 0 ] || { echo "  FAIL  pin: relay.sent is outside the broadcast's try" >&2; bad=1; }
  fi
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
pin "$CHOOSER" || { echo "FAILED (pin)"; exit 1; }
echo "pin: ok"
echo "== all checks passed"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates MediaRingRelay.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/MediaRingRelay.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutpin() { # mutpin <label> <perl-expr>   (mutates ChooserActivity.java; the pin must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  pin "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 no resend of an unchanged value" 's/return nowMs - lastSentMs >= RESEND_MS;/return false;/' || fails=$((fails+1))
mut "M2 an empty value never resent" 's/return nowMs - lastSentMs >= RESEND_MS;/return !p.isEmpty() \&\& nowMs - lastSentMs >= RESEND_MS;/' || fails=$((fails+1))
mut "M3 a uid change ignored" 's/uid != lastUid \|\| //' || fails=$((fails+1))
mutpin "M4 the poller back to its change-only test" 's/if \(!relay\.due\(prog, uid, now\)\) continue;/if (prog.equals(last) \&\& uid == lastUid) continue;/' || fails=$((fails+1))
mut "M5 reset() forgets nothing" 's/void reset\(\) \{\n.*?\n    \}/void reset() {\n    }/s' || fails=$((fails+1))
mut "M6 RESEND_MS stretched to a minute" 's/RESEND_MS = 10_000;/RESEND_MS = 60_000;/' || fails=$((fails+1))
mutpin "M7 the poller records the send before the broadcast" 's/(\n[ ]*)(Intent mpi = new Intent\("app\.nowhere\.MEDIA_PROGRESS"\))/$1relay.sent(prog, uid, now);$1$2/; s/\n[ ]*relay\.sent\(prog, uid, now\); \/\/ a broadcast that threw[^\n]*//' || fails=$((fails+1))
mutpin "M8 the poller never records a send" 's/\n[ ]*relay\.sent\(prog, uid, now\);[^\n]*//' || fails=$((fails+1))
mutpin "M9 no session does not reset the relay" 's/if \(uid < 0\) \{ relay\.reset\(\); continue; \}/if (uid < 0) { continue; }/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
