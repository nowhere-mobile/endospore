#!/usr/bin/env bash
# test-health-notice-java.sh [--mutate] -- what a health notice offers, and what its two buttons do, run under javac
# (NWP-20261201-10).
#
# WHY THIS IS COMMITTED. The decision of record (docs/product-decisions.md, 2026-11-08) says a check never repairs on
# its own and never signs a profile out, and the user decides. HealthNotice.offer is compiled with every row of its
# rule. postHealthNotice, cancelHealthNotice and HealthFixReceiver cannot compile off the build host, so their members
# are lifted and compiled against small stubs of android.*, and the buttons are read back from the stubs. The PINS read
# the sources as data.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-health-notice-java.sh            # the cases and the pins
#   bash test-health-notice-java.sh --mutate   # ... plus broken copies that must each be convicted by a named assertion
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
HN="$DIR/HealthNotice.java"
HR="$DIR/HealthFixReceiver.java"
CH="$DIR/ChooserActivity.java"
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

# The android.* stubs: just enough to compile the lifted members, and to read back what they built.
STUBS="$W/stubs"; mkdir -p "$STUBS/android/app" "$STUBS/android/content" "$STUBS/android/os" "$STUBS/android/util" "$STUBS/android/graphics/drawable"
cat > "$STUBS/android/os/UserHandle.java" <<'EOF'
package android.os;
public class UserHandle { public final int id; UserHandle(int i) { id = i; } public static UserHandle of(int i) { return new UserHandle(i); } }
EOF
cat > "$STUBS/android/util/Log.java" <<'EOF'
package android.util;
public class Log { public static int i(String t, String m) { System.out.println("LOG " + m); return 0; } public static int w(String t, String m, Throwable e) { System.out.println("LOGW " + m + " " + e); return 0; } }
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
    public Context createContextAsUser(android.os.UserHandle h, int f) { return new Context(h.id); }
    public <T> T getSystemService(Class<T> c) { return c.cast(new android.app.NotificationManager(this)); }
}
EOF
cat > "$STUBS/android/content/Intent.java" <<'EOF'
package android.content;
public class Intent {
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000;
    public Class<?> target; public String className; public int flags; public int extras;
    public Intent() {}
    public Intent(Context c, Class<?> t) { target = t; }
    public Intent setClassName(Context c, String n) { className = n; return this; }
    public Intent addFlags(int f) { flags |= f; return this; }
    public Intent putExtra(String k, boolean v) { extras++; return this; }
    public Intent putExtra(String k, String v) { extras++; return this; }
    public Intent putExtra(String k, int v) { extras++; return this; }
}
EOF
cat > "$STUBS/android/content/BroadcastReceiver.java" <<'EOF'
package android.content;
public abstract class BroadcastReceiver {
    public static class PendingResult { public final java.util.concurrent.CountDownLatch finished = new java.util.concurrent.CountDownLatch(1); public void finish() { finished.countDown(); } }
    public static final PendingResult LAST = new PendingResult();
    public final PendingResult goAsync() { return LAST; }
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
    public static PendingIntent getActivity(android.content.Context c, int r, android.content.Intent i, int f) { return new PendingIntent("activity", c, i, f); }
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
    public static int lastUser = -1, posts = 0, cancels = 0, lastId = -1, lastImportance = -1; public static Notification last;
    final android.content.Context c;
    public NotificationManager(android.content.Context c) { this.c = c; }
    public void createNotificationChannel(NotificationChannel ch) { lastImportance = ch.importance; }
    public void notify(int id, Notification n) { posts++; lastUser = c.user; lastId = id; last = n; }
    public void cancel(int id) { cancels++; lastUser = c.user; lastId = id; }
}
EOF
cat > "$STUBS/android/app/Notification.java" <<'EOF'
package android.app;
import java.util.*;
public class Notification {
    public List<Action> actions = new ArrayList<>(); public CharSequence title, text; public boolean alertOnce, ongoing; public Style style;
    public static class Style {}
    public static class BigTextStyle extends Style { public CharSequence big; public BigTextStyle bigText(CharSequence c) { big = c; return this; } }
    public static class Action {
        public CharSequence title; public PendingIntent intent;
        public static class Builder { Action a = new Action(); public Builder(android.graphics.drawable.Icon i, CharSequence t, PendingIntent p) { a.title = t; a.intent = p; } public Action build() { return a; } }
    }
    public static class Builder {
        Notification n = new Notification();
        public Builder(android.content.Context c, String ch) {}
        public Builder setSmallIcon(int i) { return this; }
        public Builder setContentTitle(CharSequence c) { n.title = c; return this; }
        public Builder setContentText(CharSequence c) { n.text = c; return this; }
        public Builder setStyle(Style s) { n.style = s; return this; }
        public Builder addAction(Action a) { n.actions.add(a); return this; }
        public Builder setOnlyAlertOnce(boolean b) { n.alertOnce = b; return this; }
        public Builder setOngoing(boolean b) { n.ongoing = b; return this; }
        public Builder setShowWhen(boolean b) { return this; }
        public Notification build() { return n; }
    }
}
EOF

CASES="$W/HealthNoticeCases.java"
cat > "$CASES" <<'EOF'
package com.nowhere.chooser;
import java.util.*;
import android.app.*;
import android.content.*;
public class HealthNoticeCases {
    static int failed = 0;
    static void eq(String name, Object got, Object want) {
        if (!Objects.equals(got, want)) { System.out.println("--- FAIL " + name + ": got " + got + ", want " + want); failed++; }
        else System.out.println("ok   " + name);
    }
    static List<String> L(String... s) { return Arrays.asList(s); }
    static final String R = HealthNotice.RULE_ID;
    public static void main(String[] a) throws Exception {
        final int NONE = HealthNotice.NONE, KEEP = HealthNotice.KEEP, FIX = HealthNotice.FIX_ONLY, BOTH = HealthNotice.FIX_AND_SIGN_OUT;
        eq("the four offers are distinct", new HashSet<>(Arrays.asList(NONE, KEEP, FIX, BOTH)).size(), 4);

        eq("FIRING, no Fix yet -> FIX", HealthNotice.offer(L(R + " FIRING 5"), "NONE"), FIX);
        eq("FIRING, Fix 30 s ago, check 25 s ago -> FIX", HealthNotice.offer(L(R + " FIRING 25"), "30"), FIX);
        eq("FIRING, check 59 s after the Fix -> FIX", HealthNotice.offer(L(R + " FIRING 1"), "60"), FIX);
        eq("FIRING, check exactly 60 s after the Fix -> FIX_AND_SIGN_OUT", HealthNotice.offer(L(R + " FIRING 1"), "61"), BOTH);
        eq("FIRING, check 300 s after the Fix -> FIX_AND_SIGN_OUT", HealthNotice.offer(L(R + " FIRING 10"), "310"), BOTH);
        eq("FIRING, check BEFORE the Fix -> FIX", HealthNotice.offer(L(R + " FIRING 500"), "30"), FIX);
        eq("FIRING, no measured check (age -1) -> FIX", HealthNotice.offer(L(R + " FIRING -1"), "300"), FIX);
        eq("CLEAR -> NONE", HealthNotice.offer(L(R + " CLEAR 5"), "300"), NONE);
        eq("NOT-APPLICABLE -> NONE", HealthNotice.offer(L(R + " NOT-APPLICABLE -1"), "NONE"), NONE);
        eq("NONE line (no session) -> NONE", HealthNotice.offer(L("NONE"), "NONE"), NONE);
        eq("UNMEASURED -> KEEP", HealthNotice.offer(L(R + " UNMEASURED -1"), "NONE"), KEEP);
        eq("another rule's CLEAR, this rule UNMEASURED -> KEEP", HealthNotice.offer(L("other CLEAR 5", R + " UNMEASURED -1"), "NONE"), KEEP);
        eq("another rule's CLEAR, this rule FIRING -> FIX", HealthNotice.offer(L("other CLEAR 5", R + " FIRING 5"), "NONE"), FIX);
        eq("no line for this rule, another says CLEAR -> NONE", HealthNotice.offer(L("other CLEAR 5"), "NONE"), NONE);
        eq("no line for this rule, another says NOT-APPLICABLE -> NONE", HealthNotice.offer(L("other NOT-APPLICABLE -1"), "NONE"), NONE);
        eq("no line for this rule, another FIRING -> KEEP", HealthNotice.offer(L("other FIRING 5"), "NONE"), KEEP);
        eq("empty list (no daemon answer) -> KEEP", HealthNotice.offer(L(), "NONE"), KEEP);
        eq("null list -> KEEP", HealthNotice.offer(null, "NONE"), KEEP);
        eq("BLANK (a daemon without the verb) -> KEEP", HealthNotice.offer(L("BLANK"), "NONE"), KEEP);
        eq("junk line -> KEEP", HealthNotice.offer(L("garbage in here too"), "NONE"), KEEP);
        eq("unknown verdict -> KEEP", HealthNotice.offer(L(R + " MAYBE 5"), "NONE"), KEEP);
        eq("non-numeric age -> KEEP", HealthNotice.offer(L(R + " FIRING soon"), "NONE"), KEEP);
        eq("FIRING, empty fix reply -> KEEP", HealthNotice.offer(L(R + " FIRING 5"), ""), KEEP);
        eq("FIRING, null fix reply -> KEEP", HealthNotice.offer(L(R + " FIRING 5"), null), KEEP);
        eq("FIRING, DENIED fix reply -> KEEP", HealthNotice.offer(L(R + " FIRING 5"), "DENIED"), KEEP);
        eq("FIRING, junk fix reply -> KEEP", HealthNotice.offer(L(R + " FIRING 5"), "12x"), KEEP);
        eq("FIRING, a huge fix reply -> KEEP", HealthNotice.offer(L(R + " FIRING 5"), "99999999999999999999"), KEEP);

        eq("SIGN_OUT_CLASS is ProfileActivity", HealthNotice.SIGN_OUT_CLASS, "com.nowhere.chooser.ProfileActivity");
        eq("SIGN_OUT_CLASS is not the AutoLogoff alias", HealthNotice.SIGN_OUT_CLASS.contains("AutoLogoff"), false);

        Context gate = new Context(0);
        Lifted.postHealthNotice(gate, 13, FIX);
        Notification n = NotificationManager.last;
        eq("FIX posts into the session's user", NotificationManager.lastUser, 13);
        eq("FIX posts one action", n.actions.size(), 1);
        eq("FIX: the action is Fix", n.actions.get(0).title, HealthNotice.FIX);
        eq("FIX: the body", n.text, HealthNotice.BODY);
        eq("the notice alerts once", n.alertOnce, true);
        eq("the notice is dismissible", n.ongoing, false);
        eq("the channel is IMPORTANCE_DEFAULT", NotificationManager.lastImportance, NotificationManager.IMPORTANCE_DEFAULT);
        PendingIntent fix = n.actions.get(0).intent;
        eq("Fix is a broadcast", fix.kind, "broadcast");
        eq("Fix fires in the roamed user", fix.user, 13);
        eq("Fix targets HealthFixReceiver", fix.intent.target, HealthFixReceiver.class);

        Lifted.postHealthNotice(gate, 13, BOTH);
        n = NotificationManager.last;
        eq("FIX_AND_SIGN_OUT posts two actions", n.actions.size(), 2);
        eq("FIX_AND_SIGN_OUT: the body", n.text, HealthNotice.BODY_SIGN_OUT);
        eq("FIX_AND_SIGN_OUT: the second action is Sign out", n.actions.get(1).title, HealthNotice.SIGN_OUT);
        PendingIntent open = n.actions.get(1).intent;
        eq("Sign out is an activity", open.kind, "activity");
        eq("Sign out fires in the roamed user", open.user, 13);
        eq("Sign out opens the Profile screen", open.intent.className, HealthNotice.SIGN_OUT_CLASS);
        eq("Sign out carries no extras", open.intent.extras, 0);

        Lifted.cancelHealthNotice(gate, 14);
        eq("cancel reaches the session's user", NotificationManager.lastUser, 14);
        eq("cancel uses the notice's id", NotificationManager.lastId, Lifted.NOTIF_HEALTH_ID);

        new HealthFixReceiver().onReceive(new Context(13), new Intent());
        eq("the receiver finishes", BroadcastReceiver.LAST.finished.await(5, java.util.concurrent.TimeUnit.SECONDS), true);
        eq("the receiver sends exactly one request", DaemonSocket.sent.size(), 1);
        eq("the receiver sends HEALTH-FIX for the rule", DaemonSocket.sent.isEmpty() ? null : DaemonSocket.sent.get(0), "HEALTH-FIX\nplay-push-frozen\n");
        eq("the receiver's read cap is 20 s", DaemonSocket.lastCap, 20000);

        if (failed > 0) { System.out.println(failed + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
EOF

# member <file> <signature prefix>: the method from that signature to its closing "    }" line.
member() { perl -0ne 'BEGIN{$s=shift @ARGV} print $1 if /(^    \Q$s\E.*?^    \}\n)/ms' "$2" "$1"; }

# run <HealthNotice> <HealthFixReceiver> <ChooserActivity> -> 0 pass, 1 a case failed, 3 compile.
run() {
  local d p f post can id
  d=$(mktemp -d -p "$W"); p="$d/com/nowhere/chooser"; mkdir -p "$p"
  cp "$1" "$p/HealthNotice.java"; cp "$2" "$p/HealthFixReceiver.java"; cp "$CASES" "$p/HealthNoticeCases.java"
  post=$(member "$3" 'private static void postHealthNotice('); can=$(member "$3" 'private static void cancelHealthNotice(')
  id=$(grep -E 'NOTIF_HEALTH_(ID|CHANNEL) =' "$3")
  if [ -z "$post" ] || [ -z "$can" ] || [ -z "$id" ]; then echo "  ERROR the lifted members were not found" >&2; return 3; fi
  { echo 'package com.nowhere.chooser;'; echo 'import android.content.*;'; echo 'class Lifted {'
    printf '%s\n%s\n%s\n' "$id" "$post" "$can" | sed -e 's/private static/static/'; echo '}'; } > "$p/Lifted.java"
  cat > "$p/R.java" <<'EOF'
package com.nowhere.chooser;
class R { static class drawable { static final int ic_backup_warn = 1; } }
EOF
  cat > "$p/DaemonSocket.java" <<'EOF'
package com.nowhere.chooser;
class DaemonSocket {
    static final java.util.List<String> sent = new java.util.ArrayList<>();
    static int lastCap = -1;
    static String roundTrip(String m, int cap) { sent.add(m); lastCap = cap; return "OK"; }
}
EOF
  "$JAVAC" -J-Djava.io.tmpdir="$W" -nowarn -d "$d/out" $(find "$STUBS" "$p" -name '*.java') || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.HealthNoticeCases || return 1
}

# watcher <ChooserActivity>: startSyncStatusWatcher, read as data.
watcher() { perl -0ne 'print $1 if /(private void startSyncStatusWatcher\(\) \{.*?^    \}\n)/ms' "$1"; }

# pins <HealthNotice> <HealthFixReceiver> <ChooserActivity> <manifest> -> 0 pass, 1 a pin failed.
pins() {
  local bad=0 w post
  w=$(mktemp -p "$W"); watcher "$3" > "$w"; post=$(mktemp -p "$W"); member "$3" 'private static void postHealthNotice(' > "$post"
  [ -s "$w" ] && [ -s "$post" ] || { echo "  PIN   ERROR the watcher or postHealthNotice was not found" >&2; return 1; }
  if grep -qE 'DaemonSocket|LocalSocket|nowhere_login' "$1" || grep -E '^import ' "$1" | grep -qv '^import java\.util\.List;$'; then echo "  PIN   P1 HealthNotice.java must stay pure" >&2; bad=1; fi
  if grep -q 'LOGOUT' "$2"; then echo "  PIN   P2 HealthFixReceiver.java holds LOGOUT" >&2; bad=1; fi
  if grep -qE 'putExtra|AutoLogoff' "$post"; then echo "  PIN   P3 postHealthNotice puts an extra or names the AutoLogoff alias" >&2; bad=1; fi
  if grep -qE '"HEALTH-FIX|LOGOUT' "$w"; then echo "  PIN   P4 the watcher repairs on its own: it sends HEALTH-FIX or LOGOUT" >&2; bad=1; fi
  perl -0ne 'exit(/if \(uid < 0\) \{.*?if \(healthShownForUid >= 0\) \{ cancelHealthNotice\(app, healthShownForUid\);.*?continue;/s ? 0 : 1)' "$w" \
    || { echo "  PIN   P5 the no-session arm does not cancel the health notice" >&2; bad=1; }
  perl -0ne 'exit(/SLOW_EVERY != 0\) continue;[^\n]*\n\s*\{[^\n]*\n.*?HealthNotice\.offer\(DaemonSocket\.roundTripLines\("GET-HEALTH\\n", 5000\),\s*pollDaemon\("GET-HEALTH-FIX\\nplay-push-frozen\\n"\)\);/s ? 0 : 1)' "$w" \
    || { echo "  PIN   P6 the slow tick does not read GET-HEALTH and GET-HEALTH-FIX" >&2; bad=1; }
  perl -0ne 'exit(/offer != HealthNotice\.KEEP && \(healthShownForUid != uid \|\| offer != healthShownOffer\)/ ? 0 : 1)' "$w" \
    || { echo "  PIN   P7 the notice is re-posted other than on a change" >&2; bad=1; }
  [ "$(grep -c 'postHealthNotice(' "$w")" = 1 ] || { echo "  PIN   P8 the watcher posts the notice somewhere else" >&2; bad=1; }
  grep -q '<receiver android:name=".HealthFixReceiver" android:exported="false"/>' "$4" || { echo "  PIN   P9 HealthFixReceiver is not a non-exported receiver" >&2; bad=1; }
  return "$bad"
}

# suite <HealthNotice> <HealthFixReceiver> <ChooserActivity> <manifest>
suite() { pins "$@"; local p=$?; run "$1" "$2" "$3"; local r=$?; [ "$r" -ne 0 ] && return "$r"; return "$p"; }

echo "== $HN"
suite "$HN" "$HR" "$CH" "$MF" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by the assertion named -- one that does not apply or compile proves nothing)"
fails=0
# mut <label> <hn|hr|ch> <perl-expr> <the output text that must convict it>
mut() {
  local d src m hn="$HN" hr="$HR" ch="$CH" rc
  d=$(mktemp -d -p "$W")
  case "$2" in hn) src="$HN" ;; hr) src="$HR" ;; ch) src="$CH" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m" || [ ! -s "$m" ]; then echo "  ERROR     $1 -- perl failed on the mutation"; fails=$((fails+1)); return; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; fails=$((fails+1)); return; fi
  case "$2" in hn) hn="$m" ;; hr) hr="$m" ;; ch) ch="$m" ;; esac
  suite "$hn" "$hr" "$ch" "$MF" > "$d/out" 2>&1; rc=$?
  if [ "$rc" = 3 ]; then echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  elif [ "$rc" != 1 ]; then echo "  SURVIVED  $1"; fails=$((fails+1))
  elif grep -qF -- "$4" "$d/out"; then echo "  convicted $1 (by: $4)"
  else echo "  SURVIVED  $1 -- convicted only by something else, wanted: $4"; fails=$((fails+1)); fi
}
mut "M1 offer is always FIX_AND_SIGN_OUT" hn 's/(static int offer\(List<String> healthLines, String fixReply\) \{\n)/$1        if (healthLines != null) return FIX_AND_SIGN_OUT;\n/' '--- FAIL FIRING, no Fix yet -> FIX'
mut "M2 the 60 s rule is dropped" hn 's/checkAge >= 0 && fixAge - checkAge >= RECHECK_AFTER_FIX_S \? /checkAge >= 0 ? /' '--- FAIL FIRING, check 59 s after the Fix -> FIX'
mut "M3 UNMEASURED cancels" hn 's/if \(verdict\.equals\("UNMEASURED"\)\) return KEEP;/if (verdict.equals("UNMEASURED")) return NONE;/' '--- FAIL UNMEASURED -> KEEP'
mut "M4 the Sign out intent carries auto=true" ch 's/(new Intent\(\)\.setClassName\(uc, HealthNotice\.SIGN_OUT_CLASS\))/$1.putExtra("auto", true)/' 'PIN   P3 postHealthNotice puts an extra'
mut "M5 the receiver sends LOGOUT" hr 's/HEALTH-FIX\\nplay-push-frozen\\n/LOGOUT\\n/' 'PIN   P2 HealthFixReceiver.java holds LOGOUT'
mut "M6 SIGN_OUT_CLASS is the AutoLogoff alias" hn 's/"com\.nowhere\.chooser\.ProfileActivity"/"com.nowhere.chooser.AutoLogoff"/' '--- FAIL SIGN_OUT_CLASS is not the AutoLogoff alias'
mut "M7 Sign out is on every notice" ch 's/boolean signOut = offer == HealthNotice\.FIX_AND_SIGN_OUT;/boolean signOut = true;/' '--- FAIL FIX posts one action'
mut "M8 the watcher repairs on its own" ch 's/(postHealthNotice\(app, uid, offer\);\n)/$1                        pollDaemon("HEALTH-FIX\\nplay-push-frozen\\n");\n/' 'PIN   P4 the watcher repairs on its own'
mut "M9 the notice outlives the session" ch 's/\s*if \(healthShownForUid >= 0\) \{ cancelHealthNotice\(app, healthShownForUid\); healthShownForUid = -1; healthShownOffer = HealthNotice\.NONE; \}\n(\s*\/\/ NWP-20260901-06)/\n$1/' 'PIN   P5 the no-session arm'
mut "M10 the notice is re-posted every tick" ch 's/offer != HealthNotice\.KEEP && \(healthShownForUid != uid \|\| offer != healthShownOffer\)/offer != HealthNotice.KEEP/' 'PIN   P7 the notice is re-posted'
mut "M11 Fix fires in the gate" ch 's/getBroadcast\(uc, 0,\n(\s*)new Intent\(uc, HealthFixReceiver\.class\)/getBroadcast(app, 0,\n$1new Intent(uc, HealthFixReceiver.class)/' '--- FAIL Fix fires in the roamed user'
mut "M12 another rule's CLEAR cancels this rule's notice" hn 's/if \(verdict\.equals\("UNMEASURED"\)\) return KEEP;/if (verdict.equals("UNMEASURED")) return cancelSeen ? NONE : KEEP;/' "--- FAIL another rule's CLEAR, this rule UNMEASURED -> KEEP"
mut "M13 a usable-looking junk reply offers FIX" hn 's/\|\| !reply\.chars\(\)\.allMatch\(c -> c >= .0. && c <= .9.\)\) return KEEP;/|| !reply.chars().allMatch(c -> c >= (char)48 \&\& c <= (char)57)) return FIX_ONLY;/' '--- FAIL FIRING, DENIED fix reply -> KEEP'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
