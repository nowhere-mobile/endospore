#!/usr/bin/env bash
# test-coldwipe-gate-java.sh [--mutate] -- the cold-lock hard wipe's go/no-go, run under javac (NWP-20261023-06).
#
# WHY THIS IS COMMITTED. ChooserActivity.coldWipe is the gate's only path that REMOVES a cold-locked session's user
# without a sign-out. It stands down unless the GET-COLDLOCK reply names this uid AND CLAIM-COLDLOCK answered exactly
# "OK" (NWP-20261004-01), and both come before any switch or removal. An empty or GONE claim let through, or a claim
# moved after doSwitch, would remove the session an owner had just resumed, with green CI. ColdWipeGate holds the two
# rules (pure, java.lang only) and is compiled here with its cases; an ORDER check over coldWipe's body and over
# ColdWipeReceiver pins where they sit. NWP-20261106-13: an UNANSWERED reply (GET-COLDLOCK or CLAIM-COLDLOCK) is not
# "resumed": coldWipe re-arms the wipe alarm through retryColdWipe and returns, and the alarm setter is shared with
# armWipeWatcher; the order check pins both tests, the setter, and that retryColdWipe sends no daemon verb.
# NWP-20261123-20: a try that reads NONE after an unanswered one can be a CLAIM-COLDLOCK whose OK was lost, with the
# user still on the phone. The NONE branch only RECORDS the uid (sNoneRemove) and calls consumeNoneRemoval on the gate
# INSTANCE (sGate, set in onCreate, resumed or not); with no instance, onResume consumes it. The instance decides with
# its own flags: the three static flow flags, its own resumeBusy, and sResumeBusy (a static mirror of resumeBusy, for
# a resume another instance started; only the resume operation clears it, never a new instance or onDestroy).
# ColdWipeGate.onNone removes the user only when removeOnNone says yes, with reapOrphanSecondaryUsers' step
# (removeUser, then CLEAN-STORAGE only for an accepted removal); the consumer never switches or wakes. The cases run
# onNone with a fake removal; none_check pins the rest; lifecycle_check runs the extracted resume, landing, onDestroy
# and flow statements through a destroy-and-replace sequence while the first gate's resume is still pending.
# NWP-20261126-16: the wipe alarm lives in AlarmManager and outlives the persistent gate process; sWipeAlarmPi does
# not. Its identity (request code 1, the ColdWipeReceiver component) is written only in wipeAlarmPi, and
# cancelWipeWatcher also looks it up by that identity (FLAG_NO_CREATE) and cancels it. The order check pins the one
# identity and the lookup; alarm_check runs the three lifted methods on stub AlarmManager / PendingIntent classes
# through a gate-process restart (sWipeAlarmPi nulled) and requires the cancel to remove the alarm.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-coldwipe-gate-java.sh            # the cases and the order check
#   bash test-coldwipe-gate-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/ColdWipeGate.java"
CHOOSER="$SRC/ChooserActivity.java"
RECEIVER="$SRC/ColdWipeReceiver.java"
CASES="$root/core/chooser/tests/coldwipe-gate/ColdWipeGateCases.java"
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

# suite <ColdWipeGate.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  ColdWipeGate.java does not exist (the gate is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/ColdWipeGate.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ColdWipeGateCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ColdWipeGateCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# Comment lines are skipped when counting sends: coldWipe's own comment names CLEAR-COLDLOCK.
# first_line <body> <regex> -> the first matching line number, empty when none. Captured, never piped into grep -q.
first_line() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { print NR; exit }'; }

# strip <file> -> the file with comment lines blanked and trailing ` // ...` text cut (line numbers kept).
strip() { awk '{ if ($0 ~ /^[ \t]*(\/\/|\*|\/\*)/) print ""; else { sub(/[ \t]\/\/.*$/, ""); print } }' "$1"; }

# none_check <ChooserActivity.java> -> 0 when coldWipe's NONE hand-off holds (NWP-20261123-20), 1 otherwise.
# The NONE branch reads the try count before its reset, records the uid in sNoneRemove and calls the gate instance's
# consumeNoneRemoval; it removes nothing itself. consumeNoneRemoval is an INSTANCE method: it takes the hand-off once,
# its flow term carries its own resumeBusy and sResumeBusy, it removes only through ColdWipeGate.onNone (the removal
# step is dpm.removeUser, then cleanUserStorage), and it never switches or wakes. onResume consumes a hand-off left
# with no instance. Every `resumeBusy = <v>;` is followed by `sResumeBusy = <v>;`; the only other sResumeBusy write
# is the clear where a resume's switch lands. onDestroy and an initializer never write it: a destroyed gate's resume
# thread can still be waiting for its RESUME reply.
none_check() {
  local f="$1" s cb nn nm nt ns seg ho rn x a p o decl body bad=0
  s=$(mktemp -p "$W") || return 1
  strip "$f" > "$s"
  cb=$(awk '/static void coldWipe\(/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  nn=$(first_line "$cb" 'if \(clUid == null\)')
  nm=$(first_line "$cb" 'if \(!ColdWipeGate\.markerNames\(cl, uid\)\)')
  if [ -z "$nn" ] || [ -z "$nm" ]; then echo "  FAIL  none: coldWipe has no NONE or markerNames test" >&2; rm -f "$s"; return 1; fi
  nt=$(printf '%s\n' "$cb" | awk -v s="$nn" 'NR > s && /final int tries = sColdWipeTries\.get\(\);/ { print NR; exit }')
  ns=$(printf '%s\n' "$cb" | awk -v s="$nn" 'NR > s && /sColdWipeTries\.set\(0\);/ { print NR; exit }')
  if [ -z "$nt" ] || [ -z "$ns" ]; then echo "  FAIL  none: the NONE branch does not read the try count and reset it" >&2; bad=1
  elif ! { [ "$nt" -lt "$ns" ] && [ "$ns" -lt "$nm" ]; }; then
    echo "  FAIL  none: the NONE branch reads the try count after its reset (get $nt, set $ns)" >&2; bad=1; fi
  seg=$(printf '%s\n' "$cb" | awk -v s="$nn" -v e="$nm" 'NR >= s && NR < e')
  case "$seg" in *'sNoneRemove.set(new int[] {uid, tries > 0 ? 1 : 0}); handOffNone(uid); return;'*) ;;
    *) echo "  FAIL  none: the NONE branch does not record the uid and hand it off" >&2; bad=1 ;; esac
  for x in 'removeOnNone' 'onNone(' 'removeUser(' 'cleanUserStorage(' 'switchUser(' 'doSwitch(' 'doRemove(' 'wake' 'Wake' \
           'sessionLive' 'resumeBusy' 'ResumeBusy'; do
    case "$seg" in *"$x"*) echo "  FAIL  none: the NONE branch reads or calls $x itself; it only records the uid" >&2; bad=1 ;; esac
  done
  ho=$(awk '/private static void handOffNone\(int uid\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  for x in 'ChooserActivity g = sGate;' 'if (g != null) g.consumeNoneRemoval();'; do
    case "$ho" in *"$x"*) ;; *) echo "  FAIL  none: handOffNone lacks: $x" >&2; bad=1 ;; esac
  done
  for x in 'removeOnNone' 'onNone(' 'removeUser(' 'cleanUserStorage(' 'switchUser(' 'doSwitch(' 'doRemove(' 'wake' 'Wake' \
           'sessionLive' 'resumeBusy' 'ResumeBusy'; do
    case "$ho" in *"$x"*) echo "  FAIL  none: handOffNone reads or calls $x itself; the gate instance decides" >&2; bad=1 ;; esac
  done
  rn=$(awk '/private void consumeNoneRemoval\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  [ -n "$rn" ] || { echo "  FAIL  none: no instance method private void consumeNoneRemoval()" >&2; rm -f "$s"; return 1; }
  for x in 'final int[] p = sNoneRemove.getAndSet(null);' \
           'boolean exists = dpm.getSecondaryUsers(admin).contains(uh);' 'boolean unlocked = um.isUserUnlocked(uh);' \
           'boolean current = android.app.ActivityManager.getCurrentUser() == uid;' \
           'boolean flow = sessionLive || signingOut || loginInProgress || resumeBusy || sResumeBusy;' \
           'int r = ColdWipeGate.onNone(uid, p[1] != 0, exists, unlocked, current, flow, new ColdWipeGate.NoneRemoval() {' \
           'return dpm.removeUser(admin, android.os.UserHandle.of(u));' \
           'public void cleanStorage(int u) { cleanUserStorage(u); }'; do
    case "$rn" in *"$x"*) ;; *) echo "  FAIL  none: consumeNoneRemoval lacks: $x" >&2; bad=1 ;; esac
  done
  o=$(printf '%s\n' "$rn" | awk '/dpm\.removeUser\(|cleanUserStorage\(/ { n++ } END { print n + 0 }')
  [ "$o" -eq 2 ] || { echo "  FAIL  none: consumeNoneRemoval calls removeUser/cleanUserStorage $o time(s), want 2 (inside onNone's step)" >&2; bad=1; }
  for x in 'switchUser(' 'doSwitch(' 'doRemove(' 'markGateSwitch(' 'wakeUp' 'WakeLock' 'coldWakeAcquire' \
           'FULL_WAKE_LOCK' 'ACQUIRE_CAUSES_WAKEUP'; do
    case "$rn" in *"$x"*) echo "  FAIL  none: consumeNoneRemoval calls $x; the removal neither switches nor wakes" >&2; bad=1 ;; esac
  done
  body=$(awk '/protected void onResume\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  case "$body" in *'if (sNoneRemove.get() != null) new Thread(this::consumeNoneRemoval).start();'*) ;;
    *) echo "  FAIL  none: onResume does not consume a pending NONE hand-off" >&2; bad=1 ;; esac
  body=$(awk '/protected void onCreate\(Bundle b\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  case "$body" in *'sGate = this;'*) ;; *) echo "  FAIL  none: onCreate does not set sGate" >&2; bad=1 ;; esac
  body=$(awk '/protected void onDestroy\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  case "$body" in *'if (sGate == this) sGate = null;'*) ;; *) echo "  FAIL  none: onDestroy lacks: if (sGate == this) sGate = null;" >&2; bad=1 ;; esac
  case "$body" in *ResumeBusy*) echo "  FAIL  none: onDestroy writes sResumeBusy; only the resume operation clears it" >&2; bad=1 ;; esac
  body=$(awk '/private void resume\(final String pass, final boolean keyAlreadyAsserted\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  case "$body" in *'if (switchToUser(fuid, ownedLbls)) {'*'resumeMode = false; sResumeBusy = false; finish();'*) ;;
    *) echo "  FAIL  none: a resume whose switch lands does not clear sResumeBusy" >&2; bad=1 ;; esac
  a=$(perl -0ne '$n = () = /(?<![\w.])(?<!boolean )resumeBusy = (?:true|false);/g; print $n' "$s")
  p=$(perl -0ne '$n = () = /(?<![\w.])(?<!boolean )resumeBusy = (true|false);[ ]*sResumeBusy = \1;/g; print $n' "$s")
  o=$(perl -0ne '$n = () = /(?<![\w.])(?<!boolean )sResumeBusy = (?:true|false);/g; print $n' "$s")
  decl=$(grep -cF 'private static volatile boolean sResumeBusy = false;' "$s")
  if [ "${a:-0}" -eq 0 ] || [ "$a" -ne "${p:-0}" ]; then
    echo "  FAIL  none: $a resumeBusy assignment(s), $p mirrored by sResumeBusy; want them equal" >&2; bad=1; fi
  if [ "${o:-0}" -ne $(( ${p:-0} + 1 )) ]; then
    echo "  FAIL  none: $o sResumeBusy assignment(s), want the $p mirrors plus the landing's one (nothing else clears it)" >&2; bad=1; fi
  [ "$decl" -eq 1 ] || { echo "  FAIL  none: sResumeBusy is declared $decl time(s), want 1" >&2; bad=1; }
  rm -f "$s"
  [ "$bad" -eq 0 ]
}

# lifecycle_check <ChooserActivity.java> -> 0 when a resume's protection outlives its gate instance (RF-001).
# It lifts the shipped statements into a model gate: resume()'s start line, every resumeBusy/sResumeBusy write in
# onDestroy and on the line where the resume's switch lands, and consumeNoneRemoval's flow expression. Sequence: gate
# A starts a resume, A is destroyed, gate B is created; B's flow must hold and ColdWipeGate.removeOnNone must keep the
# user while A's resume is pending. Then A's switch lands; B's flow must clear and removeOnNone must remove.
lifecycle_check() {
  local f="$1" s rb start dest land flow d out rc
  s=$(mktemp -p "$W") || return 1
  strip "$f" > "$s"
  rb=$(awk '/private void resume\(final String pass, final boolean keyAlreadyAsserted\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  start=$(printf '%s\n' "$rb" | awk '/if \(resumeBusy\) return;/ { getline; print; exit }')
  land=$(printf '%s\n' "$rb" | awk '/if \(switchToUser\(fuid, ownedLbls\)\) \{/ { getline; print; exit }')
  dest=$(awk '/protected void onDestroy\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
  flow=$(awk '/private void consumeNoneRemoval\(\)/ { on = 1 } on && /boolean flow = / { sub(/^.*boolean flow = /, ""); sub(/;.*$/, ""); print; exit }' "$s")
  rm -f "$s"
  if [ -z "$start" ] || [ -z "$land" ] || [ -z "$flow" ]; then
    echo "  FAIL  lifecycle: resume()'s start line, its switch landing or the consumer's flow term is missing" >&2; return 1; fi
  # Keep only the resumeBusy / sResumeBusy writes (and the guard of a conditional one) of each lifted run.
  busy() { printf '%s\n' "$1" | perl -ne 'while (/((?:if \(\w+\) )?s?[rR]esumeBusy = (?:true|false);)/g) { print "$1 " }'; }
  d=$(mktemp -d -p "$W") || return 1
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$SUT" "$d/src/com/nowhere/chooser/ColdWipeGate.java"
  cat > "$d/src/com/nowhere/chooser/ColdWipeLifecycle.java" <<JAVA
package com.nowhere.chooser;
public final class ColdWipeLifecycle {
    static boolean sessionLive, signingOut, loginInProgress;
    static boolean sResumeBusy = false;
    boolean resumeBusy = false;
    void start() { $(busy "$start") }
    void destroy() { $(busy "$dest") }
    void land() { $(busy "$land") }
    boolean flow() { return $flow; }
    public static void main(String[] a) {
        int bad = 0;
        ColdWipeLifecycle gA = new ColdWipeLifecycle();
        gA.start();
        gA.destroy();
        ColdWipeLifecycle gB = new ColdWipeLifecycle();
        if (!gB.flow() || ColdWipeGate.removeOnNone(true, true, false, false, gB.flow())) {
            System.out.println("  FAIL  lifecycle: A's resume pending, A destroyed, B created: B permits the removal"); bad++;
        } else System.out.println("  ok    lifecycle: A's resume pending after A is destroyed: B keeps the user");
        gA.land();
        if (gB.flow() || !ColdWipeGate.removeOnNone(true, true, false, false, gB.flow())) {
            System.out.println("  FAIL  lifecycle: A's switch landed, but B still counts a resume in flight"); bad++;
        } else System.out.println("  ok    lifecycle: A's switch landed: B's flow term clears");
        System.exit(bad == 0 ? 0 : 1);
    }
}
JAVA
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    echo "  FAIL  lifecycle: the lifted model does not compile" >&2; rm -rf "$d"; return 1; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ColdWipeLifecycle 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ]
}

# alarm_check <ChooserActivity.java> -> 0 when the lifted wipe-alarm methods survive a gate-process restart
# (NWP-20261126-16), 1 otherwise. It lifts the sWipeAlarmPi field and the bodies of wipeAlarmPi, setWipeAlarm and
# cancelWipeWatcher into a model class, compiles them against stub android classes, and runs: arm, restart (the static
# nulled), cancel -> no alarm and no PendingIntent left, one log line; a cancel with nothing set mints nothing; arm,
# cancel in the same process -> no alarm and no log line. The stub PendingIntent matches as the system does: request
# code, component and FLAG_IMMUTABLE, never the extras.
alarm_check() {
  local f="$1" s fld m b lifted d out rc
  s=$(mktemp -p "$W") || return 1
  strip "$f" > "$s"
  fld=$(awk '/^    private static android\.app\.PendingIntent sWipeAlarmPi;$/ { print; exit }' "$s")
  lifted=""
  for m in 'private static android\.app\.PendingIntent wipeAlarmPi\(' 'private static void setWipeAlarm\(' \
           'private static void cancelWipeWatcher\('; do
    b=$(RE="$m" awk '$0 ~ ENVIRON["RE"] { on = 1 } on { print } on && /^    }$/ { exit }' "$s")
    [ -n "$b" ] || { echo "  FAIL  alarm: no method matching $m" >&2; rm -f "$s"; return 1; }
    lifted="$lifted$b"$'\n'
  done
  rm -f "$s"
  [ -n "$fld" ] || { echo "  FAIL  alarm: no field private static android.app.PendingIntent sWipeAlarmPi;" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 1
  mkdir -p "$d/src/com/nowhere/chooser" "$d/src/android/content" "$d/src/android/app" "$d/src/android/os" \
           "$d/src/android/util"
  cat > "$d/src/android/content/Context.java" <<'JAVA'
package android.content;
public class Context {
    public static final String ALARM_SERVICE = "alarm";
    public static final android.app.AlarmManager AM = new android.app.AlarmManager();
    public Object getSystemService(String n) { return ALARM_SERVICE.equals(n) ? AM : null; }
}
JAVA
  cat > "$d/src/android/content/Intent.java" <<'JAVA'
package android.content;
public class Intent {
    public final String component; public int uid = -1;
    public Intent(Context c, Class<?> k) { component = k.getName(); }
    public Intent putExtra(String k, int v) { uid = v; return this; }
}
JAVA
  cat > "$d/src/android/app/PendingIntent.java" <<'JAVA'
package android.app;
public final class PendingIntent {
    public static final int FLAG_NO_CREATE = 1 << 29, FLAG_UPDATE_CURRENT = 1 << 27, FLAG_IMMUTABLE = 1 << 26;
    public static final java.util.Map<String, PendingIntent> LIVE = new java.util.HashMap<>();
    public static int minted = 0;
    final String key;
    private PendingIntent(String k) { key = k; }
    public static PendingIntent getBroadcast(android.content.Context c, int code, android.content.Intent i, int flags) {
        String k = code + "/" + i.component + "/" + ((flags & FLAG_IMMUTABLE) != 0);
        PendingIntent p = LIVE.get(k);
        if (p != null || (flags & FLAG_NO_CREATE) != 0) return p;
        p = new PendingIntent(k); LIVE.put(k, p); minted++;
        return p;
    }
    public void cancel() { LIVE.remove(key); }
    @Override public boolean equals(Object o) { return o instanceof PendingIntent && ((PendingIntent) o).key.equals(key); }
    @Override public int hashCode() { return key.hashCode(); }
}
JAVA
  cat > "$d/src/android/app/AlarmManager.java" <<'JAVA'
package android.app;
public final class AlarmManager {
    public static final int ELAPSED_REALTIME_WAKEUP = 2;
    public final java.util.Set<PendingIntent> alarms = new java.util.HashSet<>();
    public void setExactAndAllowWhileIdle(int t, long w, PendingIntent p) { alarms.add(java.util.Objects.requireNonNull(p)); }
    public void setAndAllowWhileIdle(int t, long w, PendingIntent p) { alarms.add(java.util.Objects.requireNonNull(p)); }
    public void cancel(PendingIntent p) { alarms.remove(java.util.Objects.requireNonNull(p)); }
}
JAVA
  cat > "$d/src/android/os/SystemClock.java" <<'JAVA'
package android.os;
public final class SystemClock { public static long elapsedRealtime() { return 1000L; } }
JAVA
  cat > "$d/src/android/util/Log.java" <<'JAVA'
package android.util;
public final class Log {
    public static final java.util.List<String> LINES = new java.util.ArrayList<>();
    public static int i(String t, String m) { LINES.add(m); return 0; }
    public static int w(String t, String m) { LINES.add(m); return 0; }
    public static int w(String t, String m, Throwable e) { LINES.add(m); return 0; }
}
JAVA
  printf 'package com.nowhere.chooser;\npublic class ColdWipeReceiver {}\n' > "$d/src/com/nowhere/chooser/ColdWipeReceiver.java"
  {
    printf 'package com.nowhere.chooser;\npublic class ChooserActivity {\n%s\n%s\n' "${fld/private static/static}" \
      "${lifted//private static/static}"
    cat <<'JAVA'
    public static void main(String[] a) {
        final android.content.Context ctx = new android.content.Context();
        final java.util.Set<android.app.PendingIntent> alarms = android.content.Context.AM.alarms;
        final String gone = "hard-wipe: cancelled an alarm left by an earlier gate process (NWP-20261126-16)";
        int bad = 0;
        setWipeAlarm(ctx, 10, 1000);
        if (alarms.size() != 1) { System.out.println("  FAIL  alarm: setWipeAlarm set " + alarms.size() + " alarm(s), want 1"); bad++; }
        sWipeAlarmPi = null; // the persistent gate process restarted: the static is gone, the alarm is not
        android.util.Log.LINES.clear();
        cancelWipeWatcher(ctx);
        if (!alarms.isEmpty() || !android.app.PendingIntent.LIVE.isEmpty()) {
            System.out.println("  FAIL  alarm: after a gate-process restart the cancel left " + alarms.size()
                    + " alarm(s) and " + android.app.PendingIntent.LIVE.size() + " PendingIntent(s)"); bad++;
        } else System.out.println("  ok    alarm: a cancel after a gate-process restart removes the earlier process's alarm");
        if (!android.util.Log.LINES.contains(gone)) { System.out.println("  FAIL  alarm: the restart cancel does not log: " + gone); bad++; }
        final int minted = android.app.PendingIntent.minted;
        cancelWipeWatcher(ctx);
        if (android.app.PendingIntent.minted != minted || !android.app.PendingIntent.LIVE.isEmpty()) {
            System.out.println("  FAIL  alarm: a cancel with no alarm minted a PendingIntent; the lookup must not create one"); bad++;
        } else System.out.println("  ok    alarm: a cancel with no alarm creates no PendingIntent");
        setWipeAlarm(ctx, 11, 1000);
        android.util.Log.LINES.clear();
        cancelWipeWatcher(ctx);
        if (!alarms.isEmpty() || sWipeAlarmPi != null) { System.out.println("  FAIL  alarm: a same-process cancel left the alarm or sWipeAlarmPi"); bad++; }
        else System.out.println("  ok    alarm: a same-process cancel removes the alarm and nulls sWipeAlarmPi");
        if (android.util.Log.LINES.contains(gone)) { System.out.println("  FAIL  alarm: a same-process cancel logs the restart line"); bad++; }
        System.exit(bad == 0 ? 0 : 1);
    }
}
JAVA
  } > "$d/src/com/nowhere/chooser/ChooserActivity.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" $(find "$d/src" -name '*.java'); then
    echo "  FAIL  alarm: the lifted wipe-alarm methods do not compile" >&2; rm -rf "$d"; return 1; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ChooserActivity 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ]
}

# order <ChooserActivity.java> <ColdWipeReceiver.java> -> 0 when the shipped order holds, 1 otherwise.
order() {
  local chooser="$1" receiver="$2" body bad=0
  local null_t names_t claim_t send_first sends clear sw swc ds dr gate_ret
  local ga mu ca sw_body aw_body rc_body w_ret t_ret a_to a_set rc_n rc_d rc_p callers
  local st wp_body cw_body n_int n_cls b_int b_cls cw_sync cw_look cw_amc
  body=$(awk '/static void coldWipe\(/ { on = 1 } on { print } on && /^    }$/ { exit }' "$chooser")
  [ -n "$body" ] || { echo "  FAIL  coldWipe not found in $chooser" >&2; return 1; }

  null_t=$(first_line "$body" 'if \(clUid == null\)')
  names_t=$(first_line "$body" 'if \(!ColdWipeGate\.markerNames\(cl, uid\)\)')
  claim_t=$(first_line "$body" 'if \(!ColdWipeGate\.claimed\(claim\)\)')
  send_first=$(first_line "$body" 'CLAIM-COLDLOCK\\n')
  sends=$(printf '%s\n' "$body" | awk '$0 !~ /^[ \t]*\/\// && /"CLAIM-COLDLOCK\\n"/ { n++ } END { print n + 0 }')
  clear=$(printf '%s\n' "$body" | awk '$0 !~ /^[ \t]*\/\// && /CLEAR-COLDLOCK/ { n++ } END { print n + 0 }')
  sw=$(first_line "$body" 'markGateSwitch\(')
  swc=$(first_line "$body" 'am\.switchUser\(')
  ds=$(first_line "$body" 'doSwitch\(')
  dr=$(first_line "$body" 'doRemove\(')
  # The line after each test must be its own stand-down (a `return`, within the next three lines).
  ret_after() { printf '%s\n' "$body" | awk -v s="$1" 'NR > s && NR <= s + 3 && /return;/ { print NR; exit }'; }

  for v in null_t names_t claim_t send_first sw swc ds dr; do
    [ -n "${!v}" ] || { echo "  FAIL  order: coldWipe has no $v line" >&2; bad=1; }
  done
  ga=$(first_line "$body" 'if \(ColdWipeGate\.unanswered\(cl\)\)')
  mu=$(first_line "$body" 'ColdWipeGate\.markerUid\(cl\)')
  ca=$(first_line "$body" 'if \(ColdWipeGate\.unanswered\(claim\)\)')
  for v in ga mu ca; do
    [ -n "${!v}" ] || { echo "  FAIL  order: coldWipe has no $v line (the unanswered tests)" >&2; bad=1; }
  done
  [ "$bad" -eq 0 ] || return 1
  # retry_ret <line>: a `return;` on that line or within the next three, at or after a retryColdWipe( call.
  retry_ret() { printf '%s\n' "$body" | awk -v s="$1" 'NR >= s && NR <= s + 3 { if (/retryColdWipe\(/) r = 1; if (r && /return;/) { print NR; exit } }'; }
  [ -n "$(retry_ret "$ga")" ] || { echo "  FAIL  order: the GET-COLDLOCK unanswered test does not retry and return" >&2; bad=1; }
  [ -n "$(retry_ret "$ca")" ] || { echo "  FAIL  order: the CLAIM-COLDLOCK unanswered test does not retry and return" >&2; bad=1; }
  [ "$ga" -lt "$mu" ] || { echo "  FAIL  order: the GET-COLDLOCK unanswered test is not before markerUid" >&2; bad=1; }
  [ "$ga" -lt "$null_t" ] || { echo "  FAIL  order: the GET-COLDLOCK unanswered test is not before the null-marker test" >&2; bad=1; }
  [ "$send_first" -lt "$ca" ] || { echo "  FAIL  order: the CLAIM-COLDLOCK unanswered test is before the send" >&2; bad=1; }
  [ "$ca" -lt "$claim_t" ] || { echo "  FAIL  order: the CLAIM-COLDLOCK unanswered test is not before the claimed test" >&2; bad=1; }
  # mbody <file> <regex>: a method's body, from its signature to the closing brace at four spaces.
  mbody() { RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
  sw_body=$(mbody "$chooser" 'private static void setWipeAlarm\(')
  [ -n "$sw_body" ] || { echo "  FAIL  order: setWipeAlarm not found" >&2; bad=1; }
  # NWP-20261126-16: the alarm's identity is written once, in wipeAlarmPi; setWipeAlarm and the cancel use it.
  st=$(mktemp -p "$W") || return 1
  strip "$chooser" > "$st"
  sw_body=$(mbody "$st" 'private static void setWipeAlarm\(')
  [ -n "$(first_line "$sw_body" 'sWipeAlarmPi = wipeAlarmPi\(appCtx, uid, android\.app\.PendingIntent\.FLAG_UPDATE_CURRENT\);')" ] \
    || { echo "  FAIL  order: setWipeAlarm does not assign sWipeAlarmPi from wipeAlarmPi(appCtx, uid, FLAG_UPDATE_CURRENT)" >&2; bad=1; }
  [ -z "$(first_line "$sw_body" 'getBroadcast\(')" ] \
    || { echo "  FAIL  order: setWipeAlarm builds its own PendingIntent; the identity lives only in wipeAlarmPi" >&2; bad=1; }
  wp_body=$(mbody "$st" 'private static android\.app\.PendingIntent wipeAlarmPi\(')
  n_int=$(awk '/new android\.content\.Intent\(appCtx, ColdWipeReceiver\.class\)/ { n++ } END { print n + 0 }' "$st")
  n_cls=$(awk '{ n += gsub(/ColdWipeReceiver\.class/, "") } END { print n + 0 }' "$st")
  b_int=$(printf '%s\n' "$wp_body" | awk '/new android\.content\.Intent\(appCtx, ColdWipeReceiver\.class\)/ { n++ } END { print n + 0 }')
  b_cls=$(printf '%s\n' "$wp_body" | awk '{ n += gsub(/ColdWipeReceiver\.class/, "") } END { print n + 0 }')
  if [ -z "$wp_body" ]; then echo "  FAIL  order: no private static android.app.PendingIntent wipeAlarmPi(...)" >&2; bad=1
  else
    [ "$n_int" -eq 1 ] && [ "$b_int" -eq 1 ] || { echo "  FAIL  order: $n_int new Intent(appCtx, ColdWipeReceiver.class) in ChooserActivity, $b_int in wipeAlarmPi; want 1 and 1" >&2; bad=1; }
    [ "$n_cls" -eq 1 ] && [ "$b_cls" -eq 1 ] || { echo "  FAIL  order: $n_cls ColdWipeReceiver.class in ChooserActivity, $b_cls in wipeAlarmPi; want 1 and 1" >&2; bad=1; }
    [ -n "$(first_line "$wp_body" 'getBroadcast\(appCtx, 1,')" ] || { echo "  FAIL  order: wipeAlarmPi does not call getBroadcast(appCtx, 1, ...)" >&2; bad=1; }
    [ -n "$(first_line "$wp_body" 'extraFlags \| android\.app\.PendingIntent\.FLAG_IMMUTABLE')" ] || { echo "  FAIL  order: wipeAlarmPi does not add FLAG_IMMUTABLE" >&2; bad=1; }
  fi
  cw_body=$(mbody "$st" 'private static void cancelWipeWatcher\(')
  rm -f "$st"
  cw_sync=$(first_line "$cw_body" 'synchronized \(ChooserActivity\.class\) \{')
  cw_look=$(first_line "$cw_body" 'pi = wipeAlarmPi\(appCtx, 0, android\.app\.PendingIntent\.FLAG_NO_CREATE\);')
  cw_amc=$(first_line "$cw_body" 'am\.cancel\(pi\);')
  if [ -z "$cw_sync" ] || [ -z "$cw_look" ] || [ -z "$cw_amc" ]; then
    echo "  FAIL  order: cancelWipeWatcher lacks its synchronized block, the FLAG_NO_CREATE lookup or am.cancel(pi)" >&2; bad=1
  elif ! { [ "$cw_sync" -lt "$cw_look" ] && [ "$cw_look" -lt "$cw_amc" ]; }; then
    echo "  FAIL  order: cancelWipeWatcher's lookup and am.cancel(pi) are not inside its synchronized block, in that order" >&2; bad=1; fi
  [ -n "$(first_line "$cw_body" 'pi\.cancel\(\);')" ] || { echo "  FAIL  order: cancelWipeWatcher does not cancel the looked-up PendingIntent" >&2; bad=1; }
  [ -n "$(first_line "$cw_body" 'sWipeAlarmPi = null;')" ] || { echo "  FAIL  order: cancelWipeWatcher does not null sWipeAlarmPi" >&2; bad=1; }
  aw_body=$(mbody "$chooser" 'private static void armWipeWatcher\(')
  a_to=$(first_line "$aw_body" 'if \(sWipeTimeoutMs <= 0\) return;')
  a_set=$(first_line "$aw_body" 'setWipeAlarm\(appCtx, uid, sWipeTimeoutMs\)')
  if [ -z "$a_to" ] || [ -z "$a_set" ]; then echo "  FAIL  order: armWipeWatcher lacks its Never return or its setWipeAlarm call" >&2; bad=1
  elif [ "$a_to" -ge "$a_set" ]; then echo "  FAIL  order: armWipeWatcher's Never return is not before setWipeAlarm" >&2; bad=1; fi
  rc_body=$(mbody "$chooser" 'private static void retryColdWipe\(')
  [ -n "$rc_body" ] || { echo "  FAIL  order: retryColdWipe not found" >&2; bad=1; }
  printf '%s\n' "$rc_body" | grep -Eq 'setWipeAlarm\(' || { echo "  FAIL  order: retryColdWipe does not call setWipeAlarm" >&2; bad=1; }
  printf '%s\n' "$rc_body" | grep -Eq 'ColdWipeGate\.retryDelayMs\(' || { echo "  FAIL  order: retryColdWipe does not use retryDelayMs" >&2; bad=1; }
  rc_d=$(printf '%s\n' "$rc_body" | awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && /DaemonSocket\./ { n++ } END { print n + 0 }')
  rc_p=$(printf '%s\n' "$rc_body" | awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && /pollDaemon\(/ { n++ } END { print n + 0 }')
  [ "$rc_d" -eq 0 ] && [ "$rc_p" -eq 0 ] || { echo "  FAIL  order: retryColdWipe talks to the daemon; a retry sends no verb" >&2; bad=1; }
  callers=$(awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && /armWipeWatcher\(/ && !/private static void armWipeWatcher/ { n++ } END { print n + 0 }' "$chooser")
  [ "$callers" -eq 1 ] || { echo "  FAIL  order: armWipeWatcher has $callers call sites, want exactly 1 (doColdLock)" >&2; bad=1; }
  [ "$bad" -eq 0 ] || return 1
  [ -n "$(ret_after "$null_t")" ]  || { echo "  FAIL  order: the null-marker test has no return" >&2; bad=1; }
  [ -n "$(ret_after "$names_t")" ] || { echo "  FAIL  order: the markerNames test has no return" >&2; bad=1; }
  gate_ret=$(ret_after "$claim_t")
  [ -n "$gate_ret" ] || { echo "  FAIL  order: the claim test has no return" >&2; bad=1; }
  [ "$null_t" -lt "$send_first" ]  || { echo "  FAIL  order: the null-marker test is not before the claim" >&2; bad=1; }
  [ "$names_t" -lt "$send_first" ] || { echo "  FAIL  order: the markerNames test is not before the claim" >&2; bad=1; }
  [ "$sends" -eq 1 ] || { echo "  FAIL  order: $sends CLAIM-COLDLOCK sends in coldWipe, want exactly 1" >&2; bad=1; }
  [ "$clear" -eq 0 ] || { echo "  FAIL  order: coldWipe sends CLEAR-COLDLOCK; the wipe claims, it never clears" >&2; bad=1; }
  if [ -n "$gate_ret" ]; then
    for v in sw swc ds dr; do
      [ "$gate_ret" -lt "${!v}" ] || { echo "  FAIL  order: the claim test's return is not before $v" >&2; bad=1; }
    done
  fi

  none_check "$chooser" || bad=1
  lifecycle_check "$chooser" || bad=1
  alarm_check "$chooser" || bad=1

  local g
  g=$(awk '/coldWipe\(/ { print }' "$receiver")
  [ "$(printf '%s\n' "$g" | awk 'NF { n++ } END { print n + 0 }')" -eq 1 ] \
    || { echo "  FAIL  receiver: coldWipe is not called exactly once" >&2; bad=1; }
  case "$g" in
    *"if (uid >= 10) ChooserActivity.coldWipe("*) ;;
    *) echo "  FAIL  receiver: coldWipe is not called under uid >= 10" >&2; bad=1 ;;
  esac
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
order "$CHOOSER" "$RECEIVER" || { echo "FAILED (order)"; exit 1; }
echo "order: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates ColdWipeGate.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ColdWipeGate.java"
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
mutord() { # mutord <label> <file: chooser|receiver> <perl-expr>   (the order check must fail)
  local d c rc f; d=$(mktemp -d -p "$W") || return 1
  if [ "$2" = chooser ]; then f="$CHOOSER"; else f="$RECEIVER"; fi
  c="$d/$(basename "$f")"
  cp "$f" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$f" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$2" = chooser ]; then order "$c" "$RECEIVER" >/dev/null 2>&1; rc=$?
  else order "$CHOOSER" "$c" >/dev/null 2>&1; rc=$?; fi
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "claimed accepts any non-null reply" 's/"OK"\.equals\(claimReply\)/claimReply != null/' || fails=$((fails+1))
mut "markerNames compares with startsWith" 's/Integer\.toString\(uid\)\.equals\(markerUid\(getColdLockReply\)\)/markerUid(getColdLockReply).startsWith(Integer.toString(uid))/' || fails=$((fails+1))
mut "markerUid without the COLDLOCK prefix test" 's/ \|\| !getColdLockReply\.startsWith\("COLDLOCK "\)//' || fails=$((fails+1))
mut "markerUid returns all of rest" 's/return sp > 0 \? rest\.substring\(0, sp\) : rest;/return rest;/' || fails=$((fails+1))
mut "unanswered treats NONE as unanswered" 's/return reply == null \|\| reply\.trim\(\)\.isEmpty\(\);/return reply == null || reply.trim().isEmpty() || "NONE".equals(reply);/' || fails=$((fails+1))
mut "retryDelayMs returns 0" 's/return triesSoFar < FAST_RETRIES \? FAST_RETRY_MS : SLOW_RETRY_MS;/return 0;/' || fails=$((fails+1))
mutord "the GET-COLDLOCK unanswered test deleted" chooser 's/\n[^\n]*if \(ColdWipeGate\.unanswered\(cl\)\)[^\n]*//' || fails=$((fails+1))
mutord "the CLAIM-COLDLOCK unanswered test deleted" chooser 's/\n[^\n]*if \(ColdWipeGate\.unanswered\(claim\)\)[^\n]*//' || fails=$((fails+1))
mutord "setWipeAlarm stops assigning sWipeAlarmPi" chooser 's/sWipeAlarmPi = (wipeAlarmPi\(appCtx, uid,)/$1/' || fails=$((fails+1))
mutord "N1 the cancel's lookup mints (FLAG_UPDATE_CURRENT for FLAG_NO_CREATE)" chooser 's/wipeAlarmPi\(appCtx, 0, android\.app\.PendingIntent\.FLAG_NO_CREATE\)/wipeAlarmPi(appCtx, 0, android.app.PendingIntent.FLAG_UPDATE_CURRENT)/' || fails=$((fails+1))
mutord "N2 the identity lookup removed from cancelWipeWatcher" chooser 's/\n            android\.app\.PendingIntent pi = null;\n.*?\n            \}\n/\n/s' || fails=$((fails+1))
mutord "N3 setWipeAlarm builds its own getBroadcast(appCtx, 2, ...)" chooser 's/sWipeAlarmPi = wipeAlarmPi\(appCtx, uid, android\.app\.PendingIntent\.FLAG_UPDATE_CURRENT\);/sWipeAlarmPi = android.app.PendingIntent.getBroadcast(appCtx, 2, new android.content.Intent(appCtx, ColdWipeReceiver.class).putExtra("uid", uid), android.app.PendingIntent.FLAG_UPDATE_CURRENT | android.app.PendingIntent.FLAG_IMMUTABLE);/' || fails=$((fails+1))
mutord "N4 the lookup's am.cancel dropped" chooser 's/\n[ ]*try \{ am\.cancel\(pi\); \} catch \(Throwable ignore\) \{\}//' || fails=$((fails+1))
mutord "the claim test moved after doSwitch" chooser 's/(                if \(!ColdWipeGate\.claimed\(claim\)\) \{.*?return;\n                \}\n)(.*?)(                doSwitch\(app, uid\);[^\n]*\n)/$2$3$1/s' || fails=$((fails+1))
mutord "a CLEAR-COLDLOCK send added before the claim" chooser 's/(                String claim = DaemonSocket)/                DaemonSocket.roundTrip("CLEAR-COLDLOCK\\n", 5000);\n$1/' || fails=$((fails+1))
mut "removeOnNone ignores the live-user guard" 's/ && !unlocked && !current//' || fails=$((fails+1))
mut "removeOnNone ignores the try count" 's/return afterUnansweredTry && /return /' || fails=$((fails+1))
mut "removeOnNone ignores the flow" 's/ && !flowRunning//' || fails=$((fails+1))
mut "onNone removes without asking removeOnNone" 's/        if \(!removeOnNone\(afterUnansweredTry, userExists, unlocked, current, flowRunning\)\) return NONE_KEPT;\n//' || fails=$((fails+1))
mut "onNone cleans storage after a refused removal" 's/        if \(!removed\) return NONE_REFUSED;\n//' || fails=$((fails+1))
mut "onNone lets a throwing removal escape" 's/try \{ removed = r\.removeUser\(uid\); \} catch \(RuntimeException e\) \{ removed = false; \}/removed = r.removeUser(uid);/' || fails=$((fails+1))
mut "onNone never removes" 's/try \{ removed = r\.removeUser\(uid\); \}/try { removed = false; }/' || fails=$((fails+1))
mutord "the NONE removal dropped (consumer's removeUser answers true)" chooser 's/return dpm\.removeUser\(admin, android\.os\.UserHandle\.of\(u\)\);/return true;/' || fails=$((fails+1))
mutord "the try count read after the reset" chooser 's/(\n[ ]*final int tries = sColdWipeTries\.get\(\);[^\n]*)(\n[ ]*sColdWipeTries\.set\(0\);)/$2$1/' || fails=$((fails+1))
mutord "sResumeBusy dropped from the flow term" chooser 's/ \|\| resumeBusy \|\| sResumeBusy;/ || resumeBusy;/' || fails=$((fails+1))
mutord "the instance's resumeBusy dropped from the flow term" chooser 's/ \|\| resumeBusy \|\| sResumeBusy;/ || sResumeBusy;/' || fails=$((fails+1))
mutord "one sResumeBusy assignment removed (resume)" chooser 's/(\n[ ]*resumeBusy = true;) sResumeBusy = true;/$1/' || fails=$((fails+1))
mutord "a new gate clears sResumeBusy (instance initializer)" chooser 's/(private volatile boolean resumeBusy = false;)/$1 { sResumeBusy = false; }/' || fails=$((fails+1))
mutord "onDestroy clears sResumeBusy (RF-001)" chooser 's/(\n[ ]*if \(sGate == this\) sGate = null;[^\n]*)/$1\n        if (resumeBusy) sResumeBusy = false;/' || fails=$((fails+1))
mutord "the switch landing does not clear sResumeBusy" chooser 's/resumeMode = false; sResumeBusy = false; finish\(\);/resumeMode = false; finish();/' || fails=$((fails+1))
mutord "the consumer made static (no instance)" chooser 's/private void consumeNoneRemoval\(\)/private static void consumeNoneRemoval()/' || fails=$((fails+1))
mutord "the NONE branch removes the user itself" chooser 's/sNoneRemove\.set\(new int/cleanUserStorage(uid); sNoneRemove.set(new int/' || fails=$((fails+1))
mutord "handOffNone does not call the gate instance" chooser 's/if \(g != null\) g\.consumeNoneRemoval\(\);/if (g != null) { }/' || fails=$((fails+1))
mutord "onCreate does not record the gate instance" chooser 's/\n[^\n]*sGate = this;[^\n]*//' || fails=$((fails+1))
mutord "onResume does not consume a pending hand-off" chooser 's/\n[^\n]*if \(sNoneRemove\.get\(\) != null\) new Thread\(this::consumeNoneRemoval\)\.start\(\);//' || fails=$((fails+1))
mutord "consumeNoneRemoval switches users" chooser 's/(\n[ ]*)boolean exists = dpm\.getSecondaryUsers/$1doSwitch(this, uid); boolean exists = dpm.getSecondaryUsers/' || fails=$((fails+1))
mutord "the receiver's uid >= 10 guard dropped" receiver 's/if \(uid >= 10\) ChooserActivity\.coldWipe/ChooserActivity.coldWipe/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
