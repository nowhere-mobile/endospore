#!/usr/bin/env bash
# test-coldlock-abort-reply-java.sh [--mutate] -- NWP-20261124-04: the gate's answer to COLD-LOCK-ABORT's COMMITTED
# reply, run under javac where it can be and pinned in the source where it cannot.
#
# An unlock after an idle cold lock committed used to read "OK" like a real abort, so the owner used a session about
# to lock. The daemon now answers COMMITTED (core/agent main.go's COLD-LOCK-ABORT arm); ColdLockAbortReply maps it to
# COVER, and the idle USER_PRESENT receiver then starts ColdLockCoverActivity INSIDE the session's user. Chester,
# 2026-11-02: "go with option 1 for 1475" -- the gate does NOT switch on COMMITTED: the daemon's own SWITCH does, after
# btpark and the releases, because the switch cycles the Bluetooth stack. So the COVER path must call no doSwitch, no
# switchUser, no ackReap and send no verb, and the watcher's SWITCH branch keeps its one WifiMirror.capture.
# Only that switch ends the cover (ColdLockCoverRule): Home, Recents and a stop before the switch raise it again, a stop
# with the screen off keeps it, and it has no noHistory flag and no timer (RF-001: the old cover finished on every stop).
#
# ColdLockAbortReply and ColdLockCoverRule are compiled ALONE and their cases run; the rest are source pins (the chooser cannot compile off
# the build host; the merger runs the whole-chooser javac check).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-coldlock-abort-reply-java.sh            # the cases and pins
#   bash test-coldlock-abort-reply-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/src/com/nowhere/chooser"
REPLY="$PKG/ColdLockAbortReply.java"
RULE="$PKG/ColdLockCoverRule.java"
CHOOSER="$PKG/ChooserActivity.java"
COVER="$PKG/ColdLockCoverActivity.java"
MANIFEST="$HERE/AndroidManifest.xml"
MAINGO="$HERE/../agent/main.go"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

# one root for everything this suite makes
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version >/dev/null 2>&1 || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$REPLY" "$RULE" "$CHOOSER" "$COVER" "$MANIFEST" "$MAINGO"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# The harness: ColdLockAbortReply alone, and every reply the daemon or a failure can produce.
HARNESS_SRC="$W/harness-src"
mkdir -p "$HARNESS_SRC/com/nowhere/chooser" || exit 2
cat > "$HARNESS_SRC/com/nowhere/chooser/ColdLockAbortReplyCases.java" <<'JAVA'
package com.nowhere.chooser;

public class ColdLockAbortReplyCases {
    static int bad = 0;
    static void want(String reply, ColdLockAbortReply.Action want) {
        ColdLockAbortReply.Action got = ColdLockAbortReply.afterReply(reply);
        if (got != want) {
            bad++;
            System.out.println("CASE afterReply(" + (reply == null ? "null" : "\"" + reply.replace("\n", "\\n") + "\"")
                    + ") = " + got + ", want " + want);
        }
    }
    public static void main(String[] a) {
        want("OK", ColdLockAbortReply.Action.ABORTED);
        want("OK\n", ColdLockAbortReply.Action.ABORTED);
        want("COMMITTED", ColdLockAbortReply.Action.COVER);
        want(" COMMITTED \n", ColdLockAbortReply.Action.COVER);
        want(null, ColdLockAbortReply.Action.NONE);
        want("", ColdLockAbortReply.Action.NONE);
        want("ERR-ARGS", ColdLockAbortReply.Action.NONE);
        want("ok", ColdLockAbortReply.Action.NONE);
        want("COMMITTEDX", ColdLockAbortReply.Action.NONE);
        System.exit(bad == 0 ? 0 : 1);
    }
}
JAVA
# The cover's lifecycle, by the path that stops it. The session is user 12; the gate is user 0.
cat > "$HARNESS_SRC/com/nowhere/chooser/ColdLockCoverRuleCases.java" <<'JAVA'
package com.nowhere.chooser;

public class ColdLockCoverRuleCases {
    static int bad = 0;
    static void want(String path, int cur, int mine, boolean on, ColdLockCoverRule.Step want) {
        ColdLockCoverRule.Step got = ColdLockCoverRule.afterStop(cur, mine, on);
        if (got != want) {
            bad++;
            System.out.println("CASE " + path + ": afterStop(" + cur + ", " + mine + ", " + on + ") = " + got + ", want " + want);
        }
    }
    public static void main(String[] a) {
        want("Home before SWITCH", 12, 12, true, ColdLockCoverRule.Step.RAISE);
        want("Recents before SWITCH", 12, 12, true, ColdLockCoverRule.Step.RAISE);
        want("a notification tap before SWITCH", 12, 12, true, ColdLockCoverRule.Step.RAISE);
        want("screen off before SWITCH", 12, 12, false, ColdLockCoverRule.Step.KEEP);
        want("the SWITCH landed", 0, 12, true, ColdLockCoverRule.Step.END);
        want("the SWITCH landed, screen off", 0, 12, false, ColdLockCoverRule.Step.END);
        want("the foreground user unread", -1, 12, true, ColdLockCoverRule.Step.RAISE);
        want("the foreground user unread, screen off", -1, 12, false, ColdLockCoverRule.Step.KEEP);
        System.exit(bad == 0 ? 0 : 1);
    }
}
JAVA

# region <file> <start-marker> <end-marker>: the text from start up to (not including) end, or exit 1.
region() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
i = s.find(sys.argv[2])
if i < 0:
    sys.exit(1)
j = s.find(sys.argv[3], i + len(sys.argv[2]))
if j < 0:
    sys.exit(1)
print(s[i:j])
PY
}

# has <text> <literal>: prints the count of <literal> in <text>.
has() { grep -cF -- "$2" <<<"$1"; }
# hasml <text> <literal>: prints the count of a literal that may span lines (grep -F splits a pattern at newlines).
hasml() { python3 -c 'import sys; print(sys.argv[1].count(sys.argv[2]))' "$1" "$2"; }

# check <ReplyJava> <ChooserJava> <CoverJava> <Manifest> <MainGo> <RuleJava>: prints a "CASE"/"PIN <id>" line per failure and
# returns non-zero on any.
check() {
  local reply="$1" chooser="$2" cover="$3" manifest="$4" maingo="$5" rule="$6" rc=0 out d arm thread helper sw onstop
  local leave step body
  d=$(mktemp -d -p "$W") || exit 2
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d" "$reply" "$HARNESS_SRC/com/nowhere/chooser/ColdLockAbortReplyCases.java" 2>&1); then
    echo "PIN J0 ColdLockAbortReply.java does not compile alone: $out"; return 1
  fi
  if ! out=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.ColdLockAbortReplyCases 2>&1); then
    echo "$out"; rc=1
  fi
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d" "$rule" "$HARNESS_SRC/com/nowhere/chooser/ColdLockCoverRuleCases.java" 2>&1); then
    echo "PIN J1 ColdLockCoverRule.java does not compile alone: $out"; return 1
  fi
  if ! out=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.ColdLockCoverRuleCases 2>&1); then
    echo "$out"; rc=1
  fi

  # The daemon's arm answers both literals.
  if ! arm=$(region "$maingo" 'if name == "COLD-LOCK-ABORT" {' $'\n\t}\n\tif name =='); then
    echo "PIN D0 the COLD-LOCK-ABORT arm not found in $maingo"; rc=1
  else
    [ "$(has "$arm" 'fmt.Fprint(conn, "COMMITTED\n")')" -ge 1 ] || { echo "PIN D1 the arm never answers COMMITTED"; rc=1; }
    [ "$(has "$arm" 'fmt.Fprint(conn, "OK\n")')" -ge 1 ] || { echo "PIN D2 the arm never answers OK"; rc=1; }
  fi

  # The receiver's abort thread maps the reply and, on COVER, starts the cover in the session user.
  if ! thread=$(region "$chooser" 'DaemonSocket.roundTrip("COLD-LOCK-ABORT\n"' '"nowhere-coldlock-abort").start();'); then
    echo "PIN R0 the nowhere-coldlock-abort thread not found"; rc=1; thread=""
  else
    [ "$(has "$thread" 'ColdLockAbortReply.afterReply(rep)')" = 1 ] || { echo "PIN R1 the thread does not map the reply through ColdLockAbortReply.afterReply"; rc=1; }
    [ "$(has "$thread" 'if (act == ColdLockAbortReply.Action.COVER) showColdLockCoverInSession(appCtx, su);')" = 1 ] \
      || { echo "PIN R2 COVER does not start the cover in the session user"; rc=1; }
    [ "$(has "$thread" '"abort committed"')" = 1 ] || { echo "PIN R3 COVER is not traced as abort committed"; rc=1; }
  fi
  if ! helper=$(region "$chooser" 'private static void showColdLockCoverInSession(Context app, int uid) {' $'\n    }\n'); then
    echo "PIN H0 showColdLockCoverInSession not found"; rc=1; helper=""
  else
    [ "$(has "$helper" 'startActivityAsUser(new Intent(app, ColdLockCoverActivity.class)')" = 1 ] \
      || { echo "PIN H1 the helper does not start ColdLockCoverActivity"; rc=1; }
    [ "$(has "$helper" 'android.os.UserHandle.of(uid)')" = 1 ] || { echo "PIN H2 the helper does not start it as the session user"; rc=1; }
  fi
  # The decision's pin: the COVER path never switches, acks a reap, sends a verb or captures Wi-Fi.
  local bad
  for bad in 'doSwitch(' 'switchUser(' 'ackReap(' 'WifiMirror.capture(' 'markColdLockIncoming(' '"LOCK' '"COLD-LOCK\n' 'setEndUserSessionMessage('; do
    if [ "$(has "$thread$helper" "$bad")" != 0 ]; then echo "PIN N the COVER path calls $bad"; rc=1; fi
  done

  # The watcher's SWITCH branch is not edited: its one capture still runs before the switch, with the session current.
  if ! sw=$(region "$chooser" 'if (reply.startsWith("SWITCH ")) {' 'main.post(() -> { doSwitch(app, uid); ackReap("SWITCH", uid); });'); then
    echo "PIN S0 the SWITCH branch's doSwitch + ackReap not found"; rc=1
  else
    [ "$(has "$sw" 'WifiMirror.capture(app);')" = 1 ] || { echo "PIN S1 the SWITCH branch does not capture Wi-Fi exactly once before its switch"; rc=1; }
  fi

  # The cover: Locking…, no way back, and only the switch ends it (RF-001).
  body=$(cat "$cover")
  [ "$(has "$body" 'tv.setText("Locking…");')" = 1 ] || { echo "PIN C1 the cover does not say Locking…"; rc=1; }
  [ "$(has "$body" '@Override public void onBackPressed() {}')" = 1 ] || { echo "PIN C2 Back leaves the cover"; rc=1; }
  if ! onstop=$(region "$cover" '@Override protected void onStop() {' $'\n    }\n'); then
    echo "PIN C3 the cover has no onStop"; rc=1
  else
    [ "$(has "$onstop" 'afterStep(ColdLockCoverRule.afterStop(currentUser(), android.os.UserHandle.myUserId(), interactive()));')" = 1 ] \
      || { echo "PIN C3 the cover's stop does not ask ColdLockCoverRule"; rc=1; }
    [ "$(has "$onstop" 'finish(')" = 0 ] || { echo "PIN C3 the cover's stop finishes without the rule"; rc=1; }
  fi
  if ! leave=$(region "$cover" '@Override protected void onUserLeaveHint() {' $'\n    }\n'); then
    echo "PIN C4 the cover does not answer Home or Recents"; rc=1
  else
    [ "$(has "$leave" 'afterStep(ColdLockCoverRule.afterStop(currentUser(), android.os.UserHandle.myUserId(), true));')" = 1 ] \
      || { echo "PIN C4 Home or Recents does not raise the cover"; rc=1; }
  fi
  if ! step=$(region "$cover" 'private void afterStep(ColdLockCoverRule.Step step) {' $'\n    }\n'); then
    echo "PIN C5 the cover has no afterStep"; rc=1
  else
    [ "$(hasml "$step" $'if (step == ColdLockCoverRule.Step.END) {\n            finish();')" = 1 ] \
      || { echo "PIN C5 the cover does not finish on END"; rc=1; }
    [ "$(hasml "$step" $'} else if (step == ColdLockCoverRule.Step.RAISE) {\n            raise();')" = 1 ] \
      || { echo "PIN C5 the cover does not raise itself on RAISE"; rc=1; }
  fi
  [ "$(has "$body" 'finish();')" = 1 ] || { echo "PIN C6 the cover finishes somewhere other than END"; rc=1; }
  [ "$(has "$body" 'postDelayed(')" = 0 ] || { echo "PIN C7 the cover has a timer"; rc=1; }
  [ "$(has "$body" 'startActivity(new Intent(this, ColdLockCoverActivity.class)')" = 1 ] \
    || { echo "PIN C8 the cover does not raise its own activity"; rc=1; }
  [ "$(has "$body" 'currentUser() {')" = 1 ] && [ "$(has "$body" 'catch (Throwable t) { return -1; }')" = 1 ] \
    || { echo "PIN C9 a failed foreground-user read does not fail closed (-1)"; rc=1; }
  local entry
  if ! entry=$(region "$manifest" '<activity android:name=".ColdLockCoverActivity"' '/>'); then
    echo "PIN M0 the manifest does not declare ColdLockCoverActivity"; rc=1
  else
    [ "$(has "$entry" 'android:exported="false"')" = 1 ] || { echo "PIN M1 the cover is exported"; rc=1; }
    [ "$(has "$entry" 'noHistory')" = 0 ] || { echo "PIN M2 the cover is noHistory: Home would finish it"; rc=1; }
    [ "$(has "$entry" 'android:excludeFromRecents="true"')" = 1 ] || { echo "PIN M3 the cover shows in recents"; rc=1; }
    [ "$(has "$entry" 'android:launchMode="singleTask"')" = 1 ] || { echo "PIN M4 a raise could make a second cover"; rc=1; }
  fi
  return "$rc"
}

echo "== cases and pins"
if ! out=$(check "$REPLY" "$CHOOSER" "$COVER" "$MANIFEST" "$MAINGO" "$RULE"); then
  echo "$out"; echo "FAILED"; exit 1
fi
echo "ok: ColdLockAbortReply and ColdLockCoverRule cases, the daemon literals, the receiver, the COVER path, the SWITCH branch, the cover and its lifecycle"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by its named failure; one that does not apply is a failure)"
fails=0
# mut <label> <want> <which: reply|rule|chooser|cover|manifest|maingo> <python-regex> <replacement>
mut() {
  local label="$1" want="$2" which="$3" d res
  local r="$REPLY" c="$CHOOSER" v="$COVER" g="$MAINGO" u="$RULE" m="$MANIFEST" src
  d=$(mktemp -d -p "$W") || exit 2
  case "$which" in
    reply) src="$REPLY"; r="$d/ColdLockAbortReply.java" ;;
    rule) src="$RULE"; u="$d/ColdLockCoverRule.java" ;;
    manifest) src="$MANIFEST"; m="$d/AndroidManifest.xml" ;;
    chooser) src="$CHOOSER"; c="$d/ChooserActivity.java" ;;
    cover) src="$COVER"; v="$d/ColdLockCoverActivity.java" ;;
    maingo) src="$MAINGO"; g="$d/main.go" ;;
  esac
  cp "$src" "$d/$(basename "$src")"
  if ! python3 - "$d/$(basename "$src")" "$4" "$5" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p, encoding="utf-8").read()
if len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
n=re.sub(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if n==s: sys.exit(1)
open(p,'w', encoding="utf-8").write(n)
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  res=$(check "$r" "$c" "$v" "$m" "$g" "$u")
  if [[ "$res" == *"$want"* ]]; then echo "  convicted $label"
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
}
mut "M1 COMMITTED mapped to NONE" "CASE afterReply(\"COMMITTED\")" reply \
  'if \("COMMITTED"\.equals\(r\)\) return Action\.COVER;' 'if ("COMMITTED".equals(r)) return Action.NONE;'
mut "M2 OK mapped to COVER" "CASE afterReply(\"OK\")" reply \
  'if \("OK"\.equals\(r\)\) return Action\.ABORTED;' 'if ("OK".equals(r)) return Action.COVER;'
mut "M3 the reply is not trimmed" "CASE afterReply(\" COMMITTED" reply \
  'reply == null \? "" : reply\.trim\(\);' 'reply == null ? "" : reply;'
mut "M4 COVER starts no cover" "PIN R2" chooser \
  '\n *if \(act == ColdLockAbortReply\.Action\.COVER\) showColdLockCoverInSession\(appCtx, su\);' ''
mut "M5 COVER re-adds doSwitch (the decision's mutant)" "PIN N the COVER path calls doSwitch(" chooser \
  '(android\.os\.UserHandle\.of\(uid\)\);\n)( *android\.util\.Log\.i\("NowhereChooser", "cold-lock committed)' '\1            doSwitch(app, uid);\n\2'
mut "M6 COVER captures Wi-Fi with the session about to go" "PIN N the COVER path calls WifiMirror.capture(" chooser \
  '(if \(act == ColdLockAbortReply\.Action\.COVER\) )showColdLockCoverInSession\(appCtx, su\);' \
  '\1{ WifiMirror.capture(appCtx); showColdLockCoverInSession(appCtx, su); }'
mut "M7 the cover starts in user 0" "PIN H2" chooser \
  'android\.os\.UserHandle\.of\(uid\)\);(\n *android\.util\.Log\.i\("NowhereChooser", "cold-lock committed)' 'android.os.UserHandle.SYSTEM);\1'
mut "M8 the SWITCH branch loses its capture" "PIN S1" chooser \
  '(if \(reply\.startsWith\("SWITCH "\)\) \{.*?)\n *WifiMirror\.capture\(app\);' '\1'
mut "M9 the daemon's COMMITTED answers OK" "PIN D1" maingo \
  'fmt\.Fprint\(conn, "COMMITTED\\n"\)' 'fmt.Fprint(conn, "OK\\n")'
mut "M10 the cover's stop never finishes (the switch leaves it up)" "PIN C5 the cover does not finish on END" cover \
  '(if \(step == ColdLockCoverRule\.Step\.END\) \{)\n *finish\(\);' '\1'
mut "M11 every stop finishes the cover (RF-001's defect)" "PIN C3 the cover's stop finishes without the rule" cover \
  '(protected void onStop\(\) \{\n *super\.onStop\(\);)' '\1\n        finish();'
mut "M12 the rule ends the cover on any stop" "CASE Home before SWITCH" rule \
  'if \(currentUser >= 0 && currentUser != coverUser\) return Step\.END;' 'if (currentUser >= 0) return Step.END;'
mut "M13 the rule never raises" "CASE Recents before SWITCH" rule \
  'return interactive \? Step\.RAISE : Step\.KEEP;' 'return Step.KEEP;'
mut "M14 the rule ends the cover when the foreground user is unread" "CASE the foreground user unread" rule \
  'if \(currentUser >= 0 && currentUser != coverUser\)' 'if (currentUser != coverUser)'
mut "M15 the rule raises with the screen off" "CASE screen off before SWITCH" rule \
  'return interactive \? Step\.RAISE : Step\.KEEP;' 'return Step.RAISE;'
mut "M16 Home and Recents do not raise the cover" "PIN C4 the cover does not answer Home" cover \
  '\n *@Override protected void onUserLeaveHint\(\) \{.*?\n    \}\n' '\n'
mut "M17 RAISE starts nothing" "PIN C5 the cover does not raise itself on RAISE" cover \
  '(\} else if \(step == ColdLockCoverRule\.Step\.RAISE\) \{\n *)raise\(\);' '\1android.util.Log.i("x", "raise");'
mut "M18 the old backstop timer re-added" "PIN C7 the cover has a timer" cover \
  '(getWindow\(\)\.addFlags\(WindowManager\.LayoutParams\.FLAG_KEEP_SCREEN_ON\);[^\n]*\n)' \
  '\1        new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(this::finish, 180_000L);\n'
mut "M19 a failed foreground-user read reads as the gate" "PIN C9" cover \
  'catch \(Throwable t\) \{ return -1; \}' 'catch (Throwable t) { return 0; }'
mut "M20 noHistory re-added (Home finishes the cover)" "PIN M2" manifest \
  '(<activity android:name="\.ColdLockCoverActivity".*?android:excludeFromRecents="true")' '\1\n              android:noHistory="true"'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
