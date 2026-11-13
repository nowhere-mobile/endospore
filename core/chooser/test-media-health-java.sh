#!/usr/bin/env bash
# test-media-health-java.sh [--mutate] -- the media-health rule: a hung media service fires, a slow or busy phone does
# not, and the notice's Fix sends only MEDIA-RESTART (NWP-20261202-26).
#
# WHY THIS IS COMMITTED. Backlog row "The phone does not notice when the session's media service stops answering,
# although restarting it brings back the alarm list, the Gallery and shared storage at once" (§B). The decision of
# record (docs/product-decisions.md, 2026-11-08) says a rule never repairs on its own and the user decides. MediaHealth
# is pure, so javac compiles the real file with no stubs and the cases drive its probe with fake Callables: a hung one
# waits on a latch that is never released, a slow one sleeps 200 ms under the 5000 ms limit, an error one throws.
# MediaFixReceiver compiles against small android.* stubs. The PINS read the sources as data.
#
# Every java run is under `timeout 60`: a probe that ignores its wait limit hangs on a hung Callable, and the guard
# reports HANG (rc 124) as a failure.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-media-health-java.sh            # the cases and the pins
#   bash test-media-health-java.sh --mutate   # ... plus broken copies that must each be convicted by a named assertion
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
MH="$DIR/MediaHealth.java"
MR="$DIR/MediaFixReceiver.java"
CH="$DIR/ChooserActivity.java"
PA="$DIR/ProfileActivity.java"
MF="$root/core/chooser/AndroidManifest.xml"
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
export TMPDIR="$W"
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: the pins need perl, and there is none -- refusing to report" >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo "FAIL: the hang guard needs timeout, and there is none" >&2; exit 2; }
for f in "$MH" "$MR" "$CH" "$PA" "$MF"; do [ -f "$f" ] || { echo "FAIL: $f is missing"; exit 1; }; done

# The android.* stubs: just enough to compile MediaFixReceiver, and to read back what it built.
STUBS="$W/stubs"; mkdir -p "$STUBS/android/app" "$STUBS/android/content" "$STUBS/android/util" "$STUBS/android/graphics/drawable"
cat > "$STUBS/android/util/Log.java" <<'EOF'
package android.util;
public class Log {
    public static final java.util.List<String> lines = java.util.Collections.synchronizedList(new java.util.ArrayList<>());
    public static int i(String t, String m) { lines.add(m); System.out.println("LOG " + m); return 0; }
    public static int w(String t, String m, Throwable e) { lines.add(m); System.out.println("LOGW " + m + " " + e); return 0; }
}
EOF
cat > "$STUBS/android/graphics/drawable/Icon.java" <<'EOF'
package android.graphics.drawable;
public class Icon {}
EOF
cat > "$STUBS/android/content/Context.java" <<'EOF'
package android.content;
public class Context {
    public final int user;
    public Context(int u) { user = u; }
    public <T> T getSystemService(Class<T> c) { return c.cast(new android.app.NotificationManager(this)); }
}
EOF
cat > "$STUBS/android/content/Intent.java" <<'EOF'
package android.content;
public class Intent {
    public Class<?> target;
    public Intent() {}
    public Intent(Context c, Class<?> t) { target = t; }
}
EOF
cat > "$STUBS/android/content/BroadcastReceiver.java" <<'EOF'
package android.content;
public abstract class BroadcastReceiver {
    public static class PendingResult { public final java.util.concurrent.CountDownLatch finished = new java.util.concurrent.CountDownLatch(1); public void finish() { finished.countDown(); } }
    public static volatile PendingResult last;
    public final PendingResult goAsync() { last = new PendingResult(); return last; }
    public abstract void onReceive(Context c, Intent i);
}
EOF
cat > "$STUBS/android/app/PendingIntent.java" <<'EOF'
package android.app;
public class PendingIntent {
    public static final int FLAG_UPDATE_CURRENT = 1, FLAG_IMMUTABLE = 2;
    public final String kind; public final int user; public final android.content.Intent intent; public final int flags;
    PendingIntent(String k, android.content.Context c, android.content.Intent i, int f) { kind = k; user = c.user; intent = i; flags = f; }
    public static PendingIntent getBroadcast(android.content.Context c, int r, android.content.Intent i, int f) { return new PendingIntent("broadcast", c, i, f); }
}
EOF
cat > "$STUBS/android/app/NotificationChannel.java" <<'EOF'
package android.app;
public class NotificationChannel { public final String id; public final int importance; public NotificationChannel(String i, CharSequence n, int imp) { id = i; importance = imp; } public void setDescription(String d) {} }
EOF
cat > "$STUBS/android/app/NotificationManager.java" <<'EOF'
package android.app;
public class NotificationManager {
    public static final int IMPORTANCE_DEFAULT = 3;
    public static int lastUser = -1, posts = 0, cancels = 0, lastId = -1; public static String lastChannel; public static Notification last;
    final android.content.Context c;
    public NotificationManager(android.content.Context c) { this.c = c; }
    public void createNotificationChannel(NotificationChannel ch) { lastChannel = ch.id; }
    public void notify(int id, Notification n) { posts++; lastUser = c.user; lastId = id; last = n; }
    public void cancel(int id) { cancels++; lastUser = c.user; lastId = id; }
    public static void reset() { lastUser = -1; posts = 0; cancels = 0; lastId = -1; lastChannel = null; last = null; }
}
EOF
cat > "$STUBS/android/app/Notification.java" <<'EOF'
package android.app;
import java.util.*;
public class Notification {
    public List<Action> actions = new ArrayList<>(); public CharSequence title, text; public boolean alertOnce, ongoing; public String channel;
    public static class Style {}
    public static class BigTextStyle extends Style { public CharSequence big; public BigTextStyle bigText(CharSequence c) { big = c; return this; } }
    public static class Action {
        public CharSequence title; public PendingIntent intent;
        public static class Builder { Action a = new Action(); public Builder(android.graphics.drawable.Icon i, CharSequence t, PendingIntent p) { a.title = t; a.intent = p; } public Action build() { return a; } }
    }
    public static class Builder {
        Notification n = new Notification();
        public Builder(android.content.Context c, String ch) { n.channel = ch; }
        public Builder setSmallIcon(int i) { return this; }
        public Builder setContentTitle(CharSequence c) { n.title = c; return this; }
        public Builder setContentText(CharSequence c) { n.text = c; return this; }
        public Builder setStyle(Style s) { return this; }
        public Builder addAction(Action a) { n.actions.add(a); return this; }
        public Builder setOnlyAlertOnce(boolean b) { n.alertOnce = b; return this; }
        public Builder setOngoing(boolean b) { n.ongoing = b; return this; }
        public Builder setShowWhen(boolean b) { return this; }
        public Notification build() { return n; }
    }
}
EOF

CASES="$W/MediaHealthCases.java"
cat > "$CASES" <<'EOF'
package com.nowhere.chooser;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import android.app.*;
import android.content.*;
public class MediaHealthCases {
    static int failed = 0;
    static void eq(String name, Object got, Object want) {
        if (!Objects.equals(got, want)) { System.out.println("--- FAIL " + name + ": got " + got + ", want " + want); failed++; }
        else System.out.println("ok   " + name);
    }
    static final List<CountDownLatch> latches = new ArrayList<>();
    static CountDownLatch latch() { CountDownLatch l = new CountDownLatch(1); latches.add(l); return l; }
    static Callable<Object> hung(final CountDownLatch l) { return () -> { l.await(); return null; }; }
    static final Callable<Object> ANSWER = () -> null;
    static final Callable<Object> SLOW = () -> { Thread.sleep(200); return null; };
    static final Callable<Object> THROWS = () -> { throw new SecurityException("refused"); };
    static final long HUNG_LIMIT = 300;

    /** One check run, as the watcher's check thread does it: probe the session, then user 0, count, decide. */
    static int run(Callable<?> s, Callable<?> o, long limit, AtomicReference<Thread> sr, AtomicReference<Thread> or, int[] misses) {
        int session = MediaHealth.probe(s, limit, sr);
        int owner = MediaHealth.probe(o, limit, or);
        misses[0] = MediaHealth.nextMisses(misses[0], session, owner);
        return MediaHealth.offer(misses[0], session);
    }
    static AtomicReference<Thread> ref() { return new AtomicReference<>(); }
    static boolean joined(AtomicReference<Thread> r) throws InterruptedException {
        Thread t = r.get();
        if (t == null) return true;
        t.join(2000);
        return !t.isAlive();
    }

    public static void main(String[] a) throws Exception {
        final int FIRE = MediaHealth.FIRE, KEEP = MediaHealth.KEEP, CANCEL = MediaHealth.CANCEL;
        eq("the three outcomes are distinct", new HashSet<>(Arrays.asList(MediaHealth.ANSWERED, MediaHealth.TIMED_OUT, MediaHealth.ERROR)).size(), 3);
        eq("the three offers are distinct", new HashSet<>(Arrays.asList(KEEP, FIRE, CANCEL)).size(), 3);
        eq("PROBE_LIMIT_MS is 5000", MediaHealth.PROBE_LIMIT_MS, 5000L);
        eq("CHECK_EVERY_MS is 5 minutes", MediaHealth.CHECK_EVERY_MS, 300000L);

        { String n = "hung session, owner answering: no FIRE on run 1, FIRE on run 2";
          AtomicReference<Thread> sr = ref(), or = ref(); int[] m = {0}; CountDownLatch ls = latch();
          int o1 = run(hung(ls), ANSWER, HUNG_LIMIT, sr, or, m);
          if (o1 == FIRE) { System.out.println("--- FAIL " + n + ": run 1 fired"); failed++; }
          int o2 = run(hung(ls), ANSWER, HUNG_LIMIT, sr, or, m);
          if (o1 != FIRE && o2 == FIRE) System.out.println("ok   " + n);
          else if (o2 != FIRE) { System.out.println("--- FAIL " + n + ": run 2 did not fire (" + o2 + ")"); failed++; } }

        { String n = "hung session, owner ERROR: FIRE on run 2";
          AtomicReference<Thread> sr = ref(), or = ref(); int[] m = {0}; CountDownLatch ls = latch();
          int o1 = run(hung(ls), THROWS, HUNG_LIMIT, sr, or, m);
          int o2 = run(hung(ls), THROWS, HUNG_LIMIT, sr, or, m);
          eq(n, o1 + "," + o2, KEEP + "," + FIRE); }

        { String n = "slow session never fires";
          AtomicReference<Thread> sr = ref(), or = ref(); int[] m = {0}; boolean fired = false;
          for (int i = 0; i < 3; i++) if (run(SLOW, ANSWER, MediaHealth.PROBE_LIMIT_MS, sr, or, m) != CANCEL) fired = true;
          eq(n, fired + " misses=" + m[0], "false misses=0"); }

        { String n = "one miss then an answer never fires";
          AtomicReference<Thread> sr = ref(), or = ref(); int[] m = {0}; CountDownLatch ls = latch();
          int o1 = run(hung(ls), ANSWER, HUNG_LIMIT, sr, or, m);
          int c1 = m[0];
          ls.countDown();
          if (!joined(sr)) { System.out.println("--- FAIL " + n + ": the run-1 session thread did not end"); failed++; }
          int o2 = run(ANSWER, ANSWER, HUNG_LIMIT, sr, or, m);
          eq(n, o1 + "," + c1 + "," + o2 + "," + m[0], KEEP + ",1," + CANCEL + ",0"); }

        { String n = "session and owner both time out: never fires and resets the count";
          AtomicReference<Thread> sr = ref(), or = ref(); int[] m = {0}; CountDownLatch ls = latch(), lo = latch();
          int o1 = run(hung(ls), ANSWER, HUNG_LIMIT, sr, or, m);
          if (m[0] != 1 || o1 == FIRE) { System.out.println("--- FAIL " + n + ": run 1 count " + m[0] + " offer " + o1); failed++; }
          int o2 = run(hung(ls), hung(lo), HUNG_LIMIT, sr, or, m);
          boolean ok2 = m[0] == 0 && o2 != FIRE;
          if (!ok2) { System.out.println("--- FAIL " + n + ": run 2 count " + m[0] + " offer " + o2); failed++; }
          lo.countDown();
          if (!joined(or)) { System.out.println("--- FAIL " + n + ": the run-2 owner thread did not end"); failed++; }
          int o3 = run(hung(ls), ANSWER, HUNG_LIMIT, sr, or, m);
          boolean ok3 = m[0] == 1 && o3 == KEEP;
          if (!ok3) { System.out.println("--- FAIL " + n + ": run 3 count " + m[0] + " offer " + o3); failed++; }
          if (ok2 && ok3) System.out.println("ok   " + n + " (counts 1, 0, 1)"); }

        { String n = "a session exception never fires";
          AtomicReference<Thread> sr = ref(), or = ref(); int[] m = {0}; boolean fired = false;
          for (int i = 0; i < 3; i++) if (run(THROWS, ANSWER, HUNG_LIMIT, sr, or, m) == FIRE) fired = true;
          eq(n, fired + " misses=" + m[0], "false misses=0");
          eq("a session exception is ERROR", MediaHealth.probe(THROWS, HUNG_LIMIT, ref()), MediaHealth.ERROR); }

        { String n = "a stuck probe blocks a second probe: TIMED_OUT, Callable not invoked";
          final AtomicInteger calls = new AtomicInteger(); final CountDownLatch l = latch();
          Callable<Object> c = () -> { calls.incrementAndGet(); l.await(); return null; };
          AtomicReference<Thread> r = ref();
          int p1 = MediaHealth.probe(c, HUNG_LIMIT, r);
          int p2 = MediaHealth.probe(c, HUNG_LIMIT, r);
          eq(n, p1 + "," + p2 + " calls=" + calls.get(), MediaHealth.TIMED_OUT + "," + MediaHealth.TIMED_OUT + " calls=1"); }

        { String n = "concurrent probes on one reference start one query (64 callers at once, 5 rounds)";
          final AtomicInteger calls = new AtomicInteger(); final CountDownLatch l = latch();
          final Callable<Object> c = () -> { calls.incrementAndGet(); l.await(); return null; };
          String worst = "";
          for (int round = 0; round < 5; round++) {
              calls.set(0);
              final AtomicReference<Thread> r = ref(); final CountDownLatch go = new CountDownLatch(1);
              final AtomicInteger notTimedOut = new AtomicInteger();
              List<Thread> callers = new ArrayList<>();
              for (int i = 0; i < 64; i++) {
                  Thread th = new Thread(() -> {
                      try { go.await(); } catch (InterruptedException e) { return; }
                      if (MediaHealth.probe(c, HUNG_LIMIT, r) != MediaHealth.TIMED_OUT) notTimedOut.incrementAndGet();
                  });
                  th.setDaemon(true); th.start(); callers.add(th);
              }
              go.countDown();
              for (Thread th : callers) th.join(10000);
              if (calls.get() != 1 || notTimedOut.get() != 0) { worst = "round " + round + " calls=" + calls.get() + " not-timed-out=" + notTimedOut.get(); break; }
          }
          eq(n, worst, ""); }

        eq("a probe that answers clears its reference", MediaHealth.probe(ANSWER, HUNG_LIMIT, ref()), MediaHealth.ANSWERED);
        eq("offer CANCEL on an answer", MediaHealth.offer(5, MediaHealth.ANSWERED), CANCEL);
        eq("offer CANCEL on an error", MediaHealth.offer(0, MediaHealth.ERROR), CANCEL);
        eq("offer KEEP on one miss", MediaHealth.offer(1, MediaHealth.TIMED_OUT), KEEP);

        eq("fixAccepted: QUEUED", MediaHealth.fixAccepted("QUEUED"), true);
        eq("fixAccepted: DENIED", MediaHealth.fixAccepted("DENIED"), false);
        eq("fixAccepted: ERR-NOSESSION", MediaHealth.fixAccepted("ERR-NOSESSION"), false);
        eq("fixAccepted: BLANK (a daemon without MEDIA-RESTART)", MediaHealth.fixAccepted("BLANK"), false);
        eq("fixAccepted: empty (no daemon)", MediaHealth.fixAccepted(""), false);
        eq("fixAccepted: null", MediaHealth.fixAccepted(null), false);

        eq("reportValue answered", MediaHealth.reportValue(MediaHealth.ANSWERED, 12), "answered ms=12");
        eq("reportValue timeout", MediaHealth.reportValue(MediaHealth.TIMED_OUT, 5003), "timeout ms=5000");
        eq("reportValue error", MediaHealth.reportValue(MediaHealth.ERROR, 3), "error");
        eq("logLine FIRING", MediaHealth.logLine(true, MediaHealth.TIMED_OUT, MediaHealth.ANSWERED, 2),
                "media health: FIRING (session=timeout owner=answered misses=2)");
        eq("logLine CLEAR", MediaHealth.logLine(false, MediaHealth.ANSWERED, MediaHealth.ERROR, 0),
                "media health: CLEAR (session=answered owner=error misses=0)");

        // MediaFixReceiver: the Fix sends only MEDIA-RESTART; a refusal re-posts without Fix and cancels nothing.
        for (String reply : new String[]{"DENIED", "ERR-NOSESSION", "BLANK", ""}) {
            String n = "fix refused re-posts without Fix (" + (reply.isEmpty() ? "no reply" : reply) + ")";
            fix(reply);
            eq(n + ": sends MEDIA-RESTART only", DaemonSocket.sent, Arrays.asList("MEDIA-RESTART\n"));
            eq(n + ": read cap 20 s", DaemonSocket.lastCap, 20000);
            eq(n + ": one post, no cancel", NotificationManager.posts + "/" + NotificationManager.cancels, "1/0");
            Notification nt = NotificationManager.last;
            eq(n, nt == null ? "none" : nt.actions.size() + " " + nt.text, "0 " + MediaHealth.BODY_NO_FIX);
            eq(n + ": the id", NotificationManager.lastId, 0x0D27);
            eq(n + ": the roamed user", NotificationManager.lastUser, 11);
            eq(n + ": logs the fixed code", android.util.Log.lines.contains("media health: fix refused"), true);
        }
        fix("QUEUED");
        eq("fix QUEUED changes nothing", NotificationManager.posts + "/" + NotificationManager.cancels + " "
                + android.util.Log.lines.contains("media health: fix refused"), "0/0 false");
        eq("fix QUEUED logs the reply word", android.util.Log.lines.contains("media fix -> QUEUED"), true);

        NotificationManager.reset();
        MediaFixReceiver.post(new Context(11), true);
        Notification nt = NotificationManager.last;
        eq("post with Fix: one action", nt.actions.size(), 1);
        eq("post with Fix: the action is Fix", nt.actions.get(0).title, MediaHealth.FIX);
        eq("post with Fix: the title and body", nt.title + " / " + nt.text, MediaHealth.TITLE + " / " + MediaHealth.BODY);
        PendingIntent pi = nt.actions.get(0).intent;
        eq("Fix is a broadcast", pi.kind, "broadcast");
        eq("Fix fires in the roamed user", pi.user, 11);
        eq("Fix targets MediaFixReceiver", pi.intent.target, MediaFixReceiver.class);
        eq("Fix is immutable", (pi.flags & PendingIntent.FLAG_IMMUTABLE) != 0, true);
        eq("the notice is dismissible", nt.ongoing, false);
        eq("the notice alerts once", nt.alertOnce, true);
        eq("the notice rides the health channel", nt.channel + " " + NotificationManager.lastChannel, "nowhere.health nowhere.health");
        eq("the notice id is 0x0D27", NotificationManager.lastId, 0x0D27);
        eq("the notice goes to the roamed user", NotificationManager.lastUser, 11);

        for (CountDownLatch l : latches) l.countDown();
        if (failed > 0) { System.out.println(failed + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }

    static void fix(String reply) throws Exception {
        NotificationManager.reset(); android.util.Log.lines.clear(); DaemonSocket.sent.clear(); DaemonSocket.lastCap = -1;
        DaemonSocket.reply = reply;
        new MediaFixReceiver().onReceive(new Context(11), new Intent());
        if (!BroadcastReceiver.last.finished.await(10, TimeUnit.SECONDS)) { System.out.println("--- FAIL the receiver did not finish"); failed++; }
    }
}
EOF

# run <MediaHealth> <MediaFixReceiver> -> 0 pass, 1 a case failed or HANG, 3 compile.
run() {
  local d p rc
  d=$(mktemp -d -p "$W"); p="$d/com/nowhere/chooser"; mkdir -p "$p"
  cp "$1" "$p/MediaHealth.java"; cp "$2" "$p/MediaFixReceiver.java"; cp "$CASES" "$p/MediaHealthCases.java"
  cat > "$p/R.java" <<'EOF'
package com.nowhere.chooser;
class R { static class drawable { static final int ic_backup_warn = 1; } }
EOF
  cat > "$p/DaemonSocket.java" <<'EOF'
package com.nowhere.chooser;
class DaemonSocket {
    static final java.util.List<String> sent = java.util.Collections.synchronizedList(new java.util.ArrayList<>());
    static volatile int lastCap = -1;
    static volatile String reply = "";
    static String roundTrip(String m, int cap) { sent.add(m); lastCap = cap; return reply; }
}
EOF
  "$JAVAC" -J-Djava.io.tmpdir="$W" -nowarn -d "$d/out" $(find "$STUBS" "$p" -name '*.java') || return 3
  timeout 60 "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.MediaHealthCases; rc=$?
  if [ "$rc" = 124 ]; then echo "HANG: the cases did not finish inside the 60 s guard"; return 1; fi
  [ "$rc" = 0 ] || return 1
}

# member <file> <signature prefix>: the method from that signature to its closing "    }" line.
member() { perl -0ne 'BEGIN{$s=shift @ARGV} print $1 if /(^    \Q$s\E.*?^    \}\n)/ms' "$2" "$1"; }
# watcher <ChooserActivity>: startSyncStatusWatcher, read as data.
watcher() { perl -0ne 'print $1 if /(private void startSyncStatusWatcher\(\) \{.*?^    \}\n)/ms' "$1"; }

# pins <MediaHealth> <MediaFixReceiver> <ChooserActivity> <ProfileActivity> <manifest> -> 0 pass, 1 a pin failed.
pins() {
  local bad=0 w rs post hpost f others sends ch_id hch_id
  w=$(mktemp -p "$W"); watcher "$3" > "$w"
  rs=$(mktemp -p "$W"); member "$4" 'static org.json.JSONObject reportStatus(' > "$rs"
  post=$(mktemp -p "$W"); member "$2" 'static void post(' > "$post"
  hpost=$(mktemp -p "$W"); member "$3" 'private static void postHealthNotice(' > "$hpost"
  [ -s "$w" ] && [ -s "$rs" ] && [ -s "$post" ] && [ -s "$hpost" ] \
    || { echo "  PIN   ERROR the watcher, reportStatus, MediaFixReceiver.post or postHealthNotice was not found" >&2; return 1; }
  if grep -qE 'android\.|DaemonSocket|LocalSocket' "$1" || grep -E '^import ' "$1" | grep -qvE '^import java\.util\.concurrent\.'; then
    echo "  PIN   P1 MediaHealth.java must stay pure (no android.*, no daemon socket)" >&2; bad=1; fi
  sends=$(grep -oE 'DaemonSocket\.[A-Za-z]+\(|connect\(' "$2" | wc -l)
  if [ "$sends" != 1 ] || ! grep -qF 'DaemonSocket.roundTrip("MEDIA-RESTART\n", READ_CAP_MS)' "$2"; then
    echo "  PIN   P2 MediaFixReceiver.java must send exactly one request, MEDIA-RESTART" >&2; bad=1; fi
  others=""
  for f in "$DIR"/*.java "$3" "$4"; do
    case "$f" in "$DIR/MediaFixReceiver.java"|"$DIR/ChooserActivity.java"|"$DIR/ProfileActivity.java") continue ;; esac
    if grep -qF '"MEDIA-RESTART' "$f"; then others="$others $(basename "$f")"; fi
  done
  [ -z "$others" ] || { echo "  PIN   P3 a file other than MediaFixReceiver.java sends MEDIA-RESTART (no automatic Fix):$others" >&2; bad=1; }
  grep -q '<receiver android:name=".MediaFixReceiver" android:exported="false"/>' "$5" \
    || { echo "  PIN   P4 MediaFixReceiver is not a non-exported receiver" >&2; bad=1; }
  perl -0ne 'exit(/if \(uid < 0\) \{.*?planSchedUid\.set\(-1\); \/\/ NWP-20261118-08\n\s*if \(mediaHealthShownUid\.get\(\) >= 0\) cancelMediaHealthNotice\(app, mediaHealthShownUid\.get\(\)\);[^\n]*mediaHealthSchedUid\.set\(-1\);.*?continue;/s ? 0 : 1)' "$w" \
    || { echo "  PIN   P5 the no-session arm does not cancel the media-health notice after the plan line" >&2; bad=1; }
  ch_id=$(perl -ne 'print $1 if /static final String CHANNEL = "([^"]*)"/' "$2")
  hch_id=$(perl -ne 'print $1 if /NOTIF_HEALTH_CHANNEL = "([^"]*)"/' "$3")
  if [ -z "$ch_id" ] || [ "$ch_id" != "$hch_id" ] \
     || [ "$(grep -oE '"Phone health"|setDescription\("[^"]*"\)' "$post")" != "$(grep -oE '"Phone health"|setDescription\("[^"]*"\)' "$hpost")" ]; then
    echo "  PIN   P6 MediaFixReceiver's channel differs from the health channel (id, name or description)" >&2; bad=1; fi
  [ "$(cat "$DIR"/*.java | grep -c '0x0D27')" = 1 ] && grep -q 'NOTIF_ID = 0x0D27;' "$2" \
    || { echo "  PIN   P7 the id 0x0D27 is not held once, by MediaFixReceiver" >&2; bad=1; }
  grep -qE 'st\.put\("media_probe", MediaHealth\.reportValue\(' "$rs" && grep -q 'REPORT_MEDIA_STUCK' "$rs" \
    || { echo "  PIN   P8 reportStatus does not put media_probe from its own probe" >&2; bad=1; }
  return "$bad"
}

# suite <MediaHealth> <MediaFixReceiver> <ChooserActivity> <ProfileActivity> <manifest>
suite() { pins "$@"; local p=$?; run "$1" "$2"; local r=$?; [ "$r" -ne 0 ] && return "$r"; return "$p"; }

echo "== $MH"
suite "$MH" "$MR" "$CH" "$PA" "$MF" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by the assertion named -- one that does not apply or compile proves nothing)"
fails=0
# mut <label> <mh|mr|ch|pa> <perl-expr> <the output text that must convict it>
mut() {
  local d src m mh="$MH" mr="$MR" ch="$CH" pa="$PA" rc
  d=$(mktemp -d -p "$W")
  case "$2" in mh) src="$MH" ;; mr) src="$MR" ;; ch) src="$CH" ;; pa) src="$PA" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m" || [ ! -s "$m" ]; then echo "  ERROR     $1 -- perl failed on the mutation"; fails=$((fails+1)); return; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; fails=$((fails+1)); return; fi
  case "$2" in mh) mh="$m" ;; mr) mr="$m" ;; ch) ch="$m" ;; pa) pa="$m" ;; esac
  suite "$mh" "$mr" "$ch" "$pa" "$MF" > "$d/out" 2>&1; rc=$?
  if [ "$rc" = 3 ]; then echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  elif [ "$rc" != 1 ]; then echo "  SURVIVED  $1"; fails=$((fails+1))
  elif grep -qF -- "$4" "$d/out"; then echo "  convicted $1 (by: $4)"
  else echo "  SURVIVED  $1 -- convicted only by something else, wanted: $4"; fails=$((fails+1)); fi
}
mut "M1 FIRE_AFTER is 1" mh 's/static final int FIRE_AFTER = 2;/static final int FIRE_AFTER = 1;/' '--- FAIL hung session, owner answering: no FIRE on run 1, FIRE on run 2'
mut "M2 the owner condition is dropped" mh 's/\n\s*if \(owner == TIMED_OUT\) return 0;[^\n]*//' '--- FAIL session and owner both time out: never fires and resets the count: run 2'
mut "M3 the busy-run reset is dropped" mh 's/if \(owner == TIMED_OUT\) return 0;/if (owner == TIMED_OUT) return misses;/' '--- FAIL session and owner both time out: never fires and resets the count: run 2'
mut "M4 the outstanding-thread guard is dropped" mh 's/if \(prev != null && prev\.isAlive\(\)\) return TIMED_OUT;//' '--- FAIL a stuck probe blocks a second probe: TIMED_OUT, Callable not invoked'
mut "M5 ERROR is counted as TIMED_OUT" mh 's/r = ERROR;/r = TIMED_OUT;/' '--- FAIL a session exception never fires'
mut "M6 the wait limit is ignored" mh 's/t\.join\(limitMs\);/t.join();/' 'HANG: the cases did not finish inside the 60 s guard'
mut "M7 the watcher repairs on its own" ch 's/(MediaFixReceiver\.post\(uc, true\);\n)/$1                        DaemonSocket.roundTrip("MEDIA-RESTART\\n", 20000);\n/' 'PIN   P3 a file other than MediaFixReceiver.java sends MEDIA-RESTART'
mut "M8 the receiver sends another verb" mr 's/"MEDIA-RESTART\\n"/"LOGOUT\\n"/' 'PIN   P2 MediaFixReceiver.java must send exactly one request, MEDIA-RESTART'
mut "M9 a refused fix re-posts WITH Fix" mr 's/post\(ctx, false\);/post(ctx, true);/' '--- FAIL fix refused re-posts without Fix (DENIED)'
mut "M10 fixAccepted accepts any reply" mh 's/if \(reply == null\) return false;/if (reply != null || reply == null) return true;/' '--- FAIL fixAccepted: DENIED'
mut "M11 the media-health notice outlives the session" ch 's/\n\s*if \(mediaHealthShownUid\.get\(\) >= 0\) cancelMediaHealthNotice\(app, mediaHealthShownUid\.get\(\)\);[^\n]*\/\/ NWP-20261202-26//' 'PIN   P5 the no-session arm'
mut "M12 the report loses media_probe" pa 's/st\.put\("media_probe", /st.put("media", /' 'PIN   P8 reportStatus does not put media_probe'
mut "M13 the reservation is not under the reference's lock" mh 's/synchronized \(outstanding\) \{/{/' '--- FAIL concurrent probes on one reference start one query'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
