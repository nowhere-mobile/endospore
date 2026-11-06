#!/usr/bin/env bash
# test-backup-now-reply-java.sh [--mutate] -- what "Back up now" on the back-online notification does with the daemon's
# BACKUP reply, run under javac (NWP-20261029-12).
#
# WHY THIS IS COMMITTED. BackupNowReceiver discarded the reply with a bare Log.i, and postSavingNotice posted on a channel
# its (roamed-user) process never created, so a BUSY refusal left the prompt unchanged (docs/backlog.md, "Back up now"
# answers BUSY and says nothing). BackupNowReply.java decides and is pure Java, so tests/backup-now-reply/run.sh compiles
# it directly with ReplyCopy and runs BackupNowReplyCases; the PINS below read the receiver and ChooserActivity as data.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK; the version
# is printed first so the log proves which compiler ran.
#
#   bash test-backup-now-reply-java.sh            # the cases and the pins
#   bash test-backup-now-reply-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
BR="$DIR/BackupNowReply.java"
RX="$DIR/BackupNowReceiver.java"
CH="$DIR/ChooserActivity.java"
RC="$DIR/ReplyCopy.java"
RUN="$here/tests/backup-now-reply/run.sh"
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
export JAVAC JAVA TMPDIR="$W"
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$RX" ] && [ -f "$CH" ] && [ -f "$RC" ] && [ -f "$RUN" ] || { echo "FAIL: missing a source or $RUN" >&2; exit 2; }

# pin <file> <label> <perl-regex>: a textual check on the glue (anchors, not line numbers).
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# suite <BackupNowReply.java> <BackupNowReceiver.java> <ChooserActivity.java> -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local br="$1" rx="$2" ch="$3"
  [ -f "$br" ] || { echo "  PIN   BackupNowReply.java does not exist" >&2; return 1; }
  pin "$rx" "decide() does not read the reply through BackupNowReply.action" \
    'private static void decide\(Context ctx, String reply\) \{.*?BackupNowReply\.action\(reply\)' || return 1
  pin "$rx" "the watchdog's abandon does not decide (finish.accept(null))" \
    'Thread\.sleep\(CONNECT_CAP_MS\).*?s\.close\(\); \} catch \(Throwable ignore\) \{\}\s*finish\.accept\(null\);' || return 1
  pin "$rx" "the worker does not decide with the daemon's reply" \
    'finally \{\s*try \{ s\.close\(\); \} catch \(Throwable ignore\) \{\}\s*finish\.accept\(got\[0\]\);' || return 1
  pin "$rx" "finish does not decide exactly once, behind the done compareAndSet" \
    'finish = r -> \{\s*if \(done\.compareAndSet\(false, true\)\) \{ decide\(ctx, r\); pr\.finish\(\); \}' || return 1
  pin "$rx" "postBackNowRefused is not called only on PROMPT" \
    'else if \(a == BackupNowReply\.PROMPT\) ChooserActivity\.postBackNowRefused\(ctx, BackupNowReply\.body\(reply\)\);' || return 1
  pin "$rx" "clearBackNowNotice is not called only on CLEAR" \
    'if \(a == BackupNowReply\.CLEAR\) ChooserActivity\.clearBackNowNotice\(ctx\);' || return 1
  [ "$(grep -c 'clearBackNowNotice(\|postBackNowRefused(' "$rx")" = 2 ] || { echo "  PIN   the receiver calls the notice helpers somewhere else" >&2; return 1; }
  pin "$ch" "postSavingNotice does not create the channel before notify" \
    'static void postSavingNotice\(Context uc, int uid\) \{(?:(?!static void).)*?createBackNowChannel\(nm\);(?:(?!static void).)*?nm\.notify\(NOTIF_BACKNOW_ID' || return 1
  pin "$ch" "postBackNowRefused does not create the channel before notify" \
    'static void postBackNowRefused\(Context uc, String body\) \{(?:(?!static void).)*?createBackNowChannel\(nm\);(?:(?!static void).)*?nm\.notify\(NOTIF_BACKNOW_ID' || return 1
  pin "$ch" "postBackNowRefused's notification has no Back up now action on the BackupNowReceiver" \
    'static void postBackNowRefused\(Context uc, String body\) \{.*?new Intent\(uc, BackupNowReceiver\.class\)(?:(?!static void).)*?\.addAction\((?:(?!static void).)*?nm\.notify\(' || return 1
  pin "$ch" "createBackNowChannel does not create NOTIF_BACKNOW_CHANNEL" \
    'private static void createBackNowChannel\(.*?new android\.app\.NotificationChannel\(\s*NOTIF_BACKNOW_CHANNEL, "Back online".*?nm\.createNotificationChannel\(ch\)' || return 1
  bash "$RUN" "$br" "$RC"
}

echo "== $BR"
suite "$BR" "$RX" "$CH" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: br|rx|ch> <perl-expr>
mut() {
  local d src m brf rxf chf rc
  d=$(mktemp -d -p "$W")
  brf="$BR"; rxf="$RX"; chf="$CH"
  case "$2" in br) src="$BR" ;; rx) src="$RX" ;; ch) src="$CH" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in br) brf="$m" ;; rx) rxf="$m" ;; ch) chf="$m" ;; esac
  suite "$brf" "$rxf" "$chf" >"$d/out" 2>&1; rc=$?
  # Only a failing CASE ("--- FAIL") or a failing PIN convicts; a compile error (rc 3) is a broken mutant.
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "Q1 BUSY read as SAVING"                  br 's/if \(f\.equals\("OK"\)\) return SAVING;/if (f.equals("OK") || f.startsWith("BUSY")) return SAVING;/' || fails=$((fails+1))
mut "Q2 LOCAL read as PROMPT"                 br 's/f\.equals\("NONE"\) \|\| f\.equals\("LOCAL"\)/f.equals("NONE")/' || fails=$((fails+1))
mut "Q3 the watchdog path makes no decision"  rx 's/(Thread\.sleep\(CONNECT_CAP_MS\).*?)finish\.accept\(null\);/$1/s' || fails=$((fails+1))
mut "Q4 postSavingNotice creates no channel"  ch 's/(static void postSavingNotice\(Context uc, int uid\) \{.*?)createBackNowChannel\(nm\);/$1/s' || fails=$((fails+1))
mut "Q5 the refused prompt has no action"     ch 's/(static void postBackNowRefused\(Context uc, String body\) \{.*?)\.addAction\(new android\.app\.Notification\.Action\.Builder\(\s*\(android\.graphics\.drawable\.Icon\) null, "Back up now", pi\)\.build\(\)\)\s*/$1/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
