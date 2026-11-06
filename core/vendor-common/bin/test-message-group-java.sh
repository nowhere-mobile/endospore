#!/usr/bin/env bash
# test-message-group-java.sh [--mutate] -- message notices carry one explicit group whose summary opens the SMS app
# (NWP-20261118-16).
#
# WHY THIS IS COMMITTED. The backlog row "Tapping a text notification in a session sometimes opens the Profile screen
# instead of the message": TelIngest posted every SMS/MMS notice with no group, and AOSP autogroups an app's ungrouped
# notices under a summary whose tap is the package's launch intent -- the chooser's is ProfileActivity, "Profile". That
# is an inference from AOSP, not reproduced. Now every message notice carries MessageGroup.KEY, and the group carries
# its own summary from the first notice on: its tap is the SMS app (messageTapIntent(ctx, null)), it never alerts on
# its own (GROUP_ALERT_CHILDREN), and it goes when no message notice remains. MessageGroup (pure java.lang) is compiled
# here with its cases (C1-C5). Source checks over TelIngest and MessagingSuppressor (P1-P7, in MessageGroupCases, on
# comment-stripped text, bodies by brace matching) pin the wiring a javac run cannot reach.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-message-group-java.sh            # the cases and the source checks
#   bash test-message-group-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
CASES="$root/core/chooser/tests/message-group/MessageGroupCases.java"
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

# suite <dir holding MessageGroup.java, TelIngest.java, MessagingSuppressor.java> -> 0 pass, 1 a case or check failed,
# 3 did not compile.
suite() {
  local dir="$1" d out rc f
  for f in MessageGroup.java TelIngest.java MessagingSuppressor.java; do
    [ -f "$dir/$f" ] || { echo "  FAIL  $f does not exist" >&2; return 1; }
  done
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$dir/MessageGroup.java" "$d/src/com/nowhere/chooser/MessageGroup.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/MessageGroupCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.MessageGroupCases "$dir" 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] || return 1
  return 0
}

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
echo "cases and source: ok"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that is inert or does not compile proves nothing)"
# mutate <label> <file name> <sed script>
mutate() {
  local label="$1" file="$2" script="$3" d rc
  d=$(mktemp -d -p "$W") || return 1
  cp "$SRC"/*.java "$d/"
  sed -i "$script" "$d/$file"
  if cmp -s "$SRC/$file" "$d/$file"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$d" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    1) echo "  convicted $label"; return 0 ;;
    0) echo "  SURVIVED  $label"; return 1 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
G=MessageGroup.java; T=TelIngest.java; S=MessagingSuppressor.java
mutate "M1 the notice without its group" $T '/private static void postRoamedMessageNotice(/,/^    }$/{/^                    \.setGroup(MessageGroup\.KEY)$/d;}' || fails=$((fails+1))
mutate "M2 the summary not a summary" $T '/^                        \.setGroupSummary(true)$/d' || fails=$((fails+1))
mutate "M3 the summary taps the launch activity" $T 's/messageTapIntent(ctx, null)/ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName())/' || fails=$((fails+1))
mutate "M4 a summary only from two notices" $G 's/return activeMessageNotices >= 1;/return activeMessageNotices >= 2;/' || fails=$((fails+1))
mutate "M5 the summary alerts on its own" $T '/^                        \.setGroupAlertBehavior(android\.app\.Notification\.GROUP_ALERT_CHILDREN)$/d' || fails=$((fails+1))
mutate "M6 the summary never cancelled" $T '/^                nm\.cancel(MessageGroup\.SUMMARY_TAG, MessageGroup\.SUMMARY_ID);$/d' || fails=$((fails+1))
mutate "M7 clearReadNotices does not re-sync" $T '/static int\[\] clearReadNotices(/,/^    }$/{/syncMessageSummary(ctx)/d;}' || fails=$((fails+1))
mutate "M8 a removed notice does not re-sync" $S '/public void onNotificationRemoved(/,/^    }$/{/TelIngest\.syncMessageSummary(this)/d;}' || fails=$((fails+1))
mutate "M9 the summary tag reads as a message tag" $G 's/"nowhere_msg_summary"/"sms:1"/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
