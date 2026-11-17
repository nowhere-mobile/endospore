#!/usr/bin/env bash
# test-backnow-one-poster-java.sh [--mutate] -- one poster for NOTIF_BACKNOW_ID: the "Back up now" tap's feedback posts
# from the user-0 chooser, as the watcher's own app uid (NWP-20261204-02).
#
# WHY THIS IS COMMITTED. The posting uid is part of a notification's key. The watcher posted the back-online prompt from
# the user-0 chooser (uid 10097 on lynx); the prompt's tap PendingIntent was created from the roamed user's context, so
# BackupNowReceiver ran in the roamed user's own process and posted "Backing up" there (uid 1410097). A tap added a
# SECOND record, the watcher's one cancel removed that one, and "Back online" stayed (NWP-20261112-53; docs/backlog.md,
# "Back up now" answers BUSY and says nothing). Now the PendingIntent is created from the user-0 context, the receiver
# runs in user 0, and every NOTIF_BACKNOW_ID notify and cancel goes into the roamed user through createContextAsUser.
#
#   (J) BackNowTarget.uid under javac: only user 0 posts, only into the foreground roamed user.
#   (S) source pins on ChooserActivity and BackupNowReceiver, comments stripped by a literal-aware scanner:
#       S1 every nm.notify/nm.cancel(NOTIF_BACKNOW_ID sits in a method whose nm comes from createContextAsUser(of(uid));
#       S2 the only Intent naming BackupNowReceiver.class is built in backNowTapIntent, whose getBroadcast takes app;
#       S3 the receiver posts nothing itself, reads myUserId() only inside BackNowTarget.uid(...), and hands app (never
#          ctx) to the helpers; S4 it posts "Backing up" only when uid > 0, and decide() returns before its helpers when
#          uid <= 0.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK.
#
#   bash test-backnow-one-poster-java.sh            # the cases and the pins
#   bash test-backnow-one-poster-java.sh --mutate   # ... plus broken copies that must each FAIL on their named check
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
BT="$DIR/BackNowTarget.java"
RX="$DIR/BackupNowReceiver.java"
CH="$DIR/ChooserActivity.java"
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
[ -f "$RX" ] && [ -f "$CH" ] || { echo "FAIL: missing $RX or $CH" >&2; exit 2; }

# The pin program: compiled once, reads the receiver and ChooserActivity as data.
PINS="$W/pins"
mkdir -p "$PINS" || exit 2
cat > "$PINS/OnePosterPins.java" <<'EOF'
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class OnePosterPins {
    static int failed = 0;

    static void pin(boolean ok, String label) {
        if (!ok) { System.err.println("  PIN   " + label); failed++; }
    }

    /** Java source with every comment replaced by a space; string and char literals kept as they are. */
    static String strip(String s) {
        StringBuilder b = new StringBuilder(s.length());
        int i = 0, n = s.length();
        while (i < n) {
            char c = s.charAt(i);
            if (c == '"' || c == '\'') {
                b.append(c); i++;
                while (i < n && s.charAt(i) != c) {
                    if (s.charAt(i) == '\\' && i + 1 < n) { b.append(s.charAt(i)); i++; }
                    b.append(s.charAt(i)); i++;
                }
                if (i < n) { b.append(c); i++; }
            } else if (c == '/' && i + 1 < n && s.charAt(i + 1) == '/') {
                while (i < n && s.charAt(i) != '\n') i++;
                b.append(' ');
            } else if (c == '/' && i + 1 < n && s.charAt(i + 1) == '*') {
                int e = s.indexOf("*/", i + 2);
                i = e < 0 ? n : e + 2;
                b.append(' ');
            } else { b.append(c); i++; }
        }
        return b.toString();
    }

    /** Index of the brace that closes the one at <open>; string and char literals skipped (comments already gone). */
    static int close(String s, int open) {
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\'') {
                for (i++; i < s.length() && s.charAt(i) != c; i++) if (s.charAt(i) == '\\') i++;
            } else if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return i;
        }
        return -1;
    }

    /** One class member: its name and its source span (header through closing brace). */
    record Method(String name, int start, int end, String text) {}

    static final Pattern HEADER = Pattern.compile(
            "(?m)^    (?:(?:public|private|protected|static|final|synchronized)\\s+)*[\\w.<>\\[\\], ]+?\\s+(\\w+)\\s*\\([^;{)]*\\)\\s*(?:throws [\\w., ]+)?\\{");

    static List<Method> methods(String s) {
        List<Method> out = new ArrayList<>();
        Matcher m = HEADER.matcher(s);
        int from = 0;
        while (m.find(from)) {
            int open = m.end() - 1;
            int end = close(s, open);
            if (end < 0) break;
            out.add(new Method(m.group(1), m.start(), end + 1, s.substring(m.start(), end + 1)));
            from = end + 1;
        }
        return out;
    }

    static Method enclosing(List<Method> ms, int at) {
        for (Method m : ms) if (m.start() <= at && at < m.end()) return m;
        return null;
    }

    static Method named(List<Method> ms, String name) {
        for (Method m : ms) if (m.name().equals(name)) return m;
        return null;
    }

    /** The argument text of the call whose "(" is at <open>. */
    static String args(String s, int open) {
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\'') {
                for (i++; i < s.length() && s.charAt(i) != c; i++) if (s.charAt(i) == '\\') i++;
            } else if (c == '(') depth++;
            else if (c == ')' && --depth == 0) return s.substring(open + 1, i);
        }
        return "";
    }

    static int count(String s, String needle) {
        int k = 0;
        for (int i = s.indexOf(needle); i >= 0; i = s.indexOf(needle, i + 1)) k++;
        return k;
    }

    public static void main(String[] a) throws Exception {
        String rx = strip(Files.readString(Path.of(a[0]), StandardCharsets.UTF_8));
        String ch = strip(Files.readString(Path.of(a[1]), StandardCharsets.UTF_8));
        List<Method> chm = methods(ch);
        List<Method> rxm = methods(rx);

        // S1: every NOTIF_BACKNOW_ID notify and cancel goes into roamed user <uid> through createContextAsUser.
        String UC = "Context uc = app.createContextAsUser(android.os.UserHandle.of(uid), 0);";
        String NM = "android.app.NotificationManager nm = uc.getSystemService(";
        Matcher post = Pattern.compile("nm\\.(?:notify|cancel)\\(NOTIF_BACKNOW_ID\\b").matcher(ch);
        List<String> posters = new ArrayList<>();
        boolean s1 = true;
        while (post.find()) {
            Method m = enclosing(chm, post.start());
            if (m == null) { s1 = false; System.err.println("        S1 " + post.group() + " outside any method"); continue; }
            if (!posters.contains(m.name())) posters.add(m.name());
            int u = m.text().indexOf(UC), v = m.text().indexOf(NM);
            if (u < 0 || v < u || m.text().indexOf(NM, v + 1) >= 0) {
                s1 = false; System.err.println("        S1 " + m.name() + " posts or cancels NOTIF_BACKNOW_ID on a NotificationManager not from " + UC);
            }
        }
        if (posters.size() < 5) { s1 = false; System.err.println("        S1 only " + posters + " post NOTIF_BACKNOW_ID (want 5 or more)"); }
        pin(s1, "S1 a NOTIF_BACKNOW_ID notify or cancel does not go through createContextAsUser(UserHandle.of(uid), 0)");

        // S2: the tap intent is built once, from the user-0 context <app>.
        Method tapM = named(chm, "backNowTapIntent");
        boolean s2 = tapM != null
                && tapM.text().startsWith("    private static android.app.PendingIntent backNowTapIntent(Context app, int uid, long reconnectAt) {")
                && tapM.text().contains("Intent tap = new Intent(app, BackupNowReceiver.class);")
                && tapM.text().contains("tap.putExtra(BackupNowReceiver.EXTRA_BACKNOW_UID, uid);")
                && tapM.text().contains("android.app.PendingIntent.getBroadcast(app, uid,")
                && count(tapM.text(), "getBroadcast(") == 1
                && !tapM.text().contains("uc");
        if (tapM == null) System.err.println("        S2 there is no backNowTapIntent");
        for (String[] src : new String[][] {{"ChooserActivity", ch}, {"BackupNowReceiver", rx}}) {
            List<Method> ms = src[0].equals("ChooserActivity") ? chm : rxm;
            Matcher in = Pattern.compile("new Intent\\(").matcher(src[1]);
            while (in.find()) {
                if (!args(src[1], in.end() - 1).contains("BackupNowReceiver.class")) continue;
                Method m = enclosing(ms, in.start());
                if (src[0].equals("BackupNowReceiver") || m == null || !m.name().equals("backNowTapIntent")) {
                    s2 = false;
                    System.err.println("        S2 " + src[0] + "." + (m == null ? "?" : m.name()) + " builds its own BackupNowReceiver intent");
                }
            }
        }
        for (String name : new String[] {"postBackNowNotice", "postBackNowRefused"}) {
            Method m = named(chm, name);
            if (m == null || !m.text().contains("android.app.PendingIntent pi = backNowTapIntent(app, uid, reconnectAt);")) {
                s2 = false; System.err.println("        S2 " + name + " does not take its tap from backNowTapIntent(app, uid, reconnectAt)");
            }
        }
        pin(s2, "S2 the tap's PendingIntent is not built only in backNowTapIntent, from the user-0 context app");

        // S3: the receiver posts nothing itself, reads its own user only as BackNowTarget's input, and hands app to the helpers.
        boolean s3 = !rx.contains("NotificationManager") && !rx.contains(".notify(") && !rx.contains(".cancel(")
                && rx.contains("final Context app = ctx.getApplicationContext();");
        int tgt = rx.indexOf("final int uid = BackNowTarget.uid(");
        String targs = tgt < 0 ? "" : args(rx, tgt + "final int uid = BackNowTarget.uid".length());
        if (count(rx, "UserHandle.myUserId()") != 1 || !targs.contains("android.os.UserHandle.myUserId()")
                || !targs.contains("intent.getIntExtra(EXTRA_BACKNOW_UID, -1)")
                || !targs.contains("android.app.ActivityManager.getCurrentUser()")) {
            s3 = false; System.err.println("        S3 the receiver's uid is not BackNowTarget.uid(extra, current user, myUserId())");
        }
        Matcher call = Pattern.compile("ChooserActivity\\.(postSavingNotice|postBackNowRefused|clearBackNowNotice|postBackNowNotice|cancelBackNowNotice)\\(").matcher(rx);
        int calls = 0;
        while (call.find()) {
            calls++;
            if (!args(rx, call.end() - 1).startsWith("app, uid")) {
                s3 = false; System.err.println("        S3 " + call.group(1) + " is not handed (app, uid, ...)");
            }
        }
        if (calls != 3) { s3 = false; System.err.println("        S3 the receiver makes " + calls + " back-now helper calls (want 3)"); }
        pin(s3, "S3 the receiver posts on its own, reads myUserId() outside BackNowTarget.uid, or hands ctx to a helper");

        // S4: nothing is posted without a target user.
        boolean s4 = count(rx, "ChooserActivity.postSavingNotice(") == 1
                && rx.contains("if (uid > 0) ChooserActivity.postSavingNotice(app, uid);");
        Method dm = named(rxm, "decide");
        if (dm == null) s4 = false;
        else {
            String d = dm.text();
            int ret = d.indexOf("if (uid <= 0) return;");
            int c1 = d.indexOf("ChooserActivity.clearBackNowNotice("), c2 = d.indexOf("ChooserActivity.postBackNowRefused(");
            if (!d.startsWith("    private static void decide(Context app, int uid, String reply, long reconnectAt) {")
                    || ret < 0 || c1 < ret || c2 < ret) s4 = false;
        }
        pin(s4, "S4 a tap with no target user posts a back-now notice");

        System.exit(failed == 0 ? 0 : 1);
    }
}
EOF
"$JAVAC" -J-Djava.io.tmpdir="$W" -d "$PINS" "$PINS/OnePosterPins.java" || { echo "FAIL: OnePosterPins does not compile" >&2; exit 2; }

# cases <BackNowTarget.java> -> 0 pass, 1 a case failed or the file is missing, 3 compile.
cases() {
  local bt="$1" d
  [ -f "$bt" ] || { echo "  PIN   J BackNowTarget.java does not exist" >&2; return 1; }
  if grep -q '^import ' "$bt"; then echo "  PIN   J BackNowTarget.java imports something (java.lang only)" >&2; return 1; fi
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$bt" "$d/src/com/nowhere/chooser/BackNowTarget.java"
  cat > "$d/src/com/nowhere/chooser/BackNowTargetCases.java" <<'EOF'
package com.nowhere.chooser;

public class BackNowTargetCases {
    static int bad = 0;

    static void eq(int extraUid, int currentUser, int myUser, int want) {
        int got = BackNowTarget.uid(extraUid, currentUser, myUser);
        String label = "J (" + extraUid + "," + currentUser + "," + myUser + ")";
        if (got == want) System.out.println("ok " + label + " -> " + got);
        else { System.out.println("--- FAIL " + label + " -> " + got + ", want " + want); bad++; }
    }

    public static void main(String[] a) {
        eq(14, 14, 0, 14);  // user 0, the tap names the foreground roamed user: post into it
        eq(14, 15, 0, -1);  // the tap names a user that is no longer in front
        eq(14, 14, 14, -1); // a prompt an older build posted fires in the roamed user's own process
        eq(-1, 14, 0, -1);  // the tap carries no user
        eq(0, 0, 0, -1);    // never post into user 0
        System.exit(bad == 0 ? 0 : 1);
    }
}
EOF
  "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/com/nowhere/chooser/"*.java >"$d/javac.out" 2>&1 \
    || { cat "$d/javac.out" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.BackNowTargetCases
}

# suite <BackNowTarget.java> <BackupNowReceiver.java> <ChooserActivity.java> -> 0 pass, 1 a case or pin failed, 3 compile.
# Every check runs, so one run names each failing check.
suite() {
  local bt="$1" rx="$2" ch="$3" rc=0 jr
  cases "$bt"; jr=$?
  [ "$jr" -eq 3 ] && return 3
  [ "$jr" -eq 0 ] || rc=1
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$PINS" OnePosterPins "$rx" "$ch" || rc=1
  [ "$rc" -eq 0 ] && echo "all checks passed"
  return "$rc"
}

echo "== $BT"
suite "$BT" "$RX" "$CH" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named check -- a mutant that does not apply or compile proves nothing)"
# mut <label> <convicting check, as it is printed> <which: bt|rx|ch> <perl-expr>
mut() {
  local d src m btf rxf chf rc
  d=$(mktemp -d -p "$W")
  btf="$BT"; rxf="$RX"; chf="$CH"
  case "$3" in bt) src="$BT" ;; rx) src="$RX" ;; ch) src="$CH" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$4" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$3" in bt) btf="$m" ;; rx) rxf="$m" ;; ch) chf="$m" ;; esac
  suite "$btf" "$rxf" "$chf" >"$d/out" 2>&1; rc=$?
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) if grep -qF -- "$2" "$d/out"; then echo "  convicted $1 ($2)"; return 0; fi
       echo "  WRONG     $1 -- failed, but not on its named check '$2':"; sed 's/^/            /' "$d/out"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 backNowTapIntent's getBroadcast takes uc" "PIN   S2" ch \
  's/PendingIntent\.getBroadcast\(app, uid,/PendingIntent.getBroadcast(uc, uid,/' || fails=$((fails+1))
mut "M2 postSavingNotice posts on the context it is handed" "PIN   S1" ch \
  's/(static void postSavingNotice\(Context app, int uid\) \{\s*try \{\s*)Context uc = app\.createContextAsUser\(android\.os\.UserHandle\.of\(uid\), 0\);/$1Context uc = app;/s' || fails=$((fails+1))
mut "M3 the receiver passes myUserId() as the uid" "PIN   S3" rx \
  's/final int uid = BackNowTarget\.uid\(.*?\);/final int uid = android.os.UserHandle.myUserId();/s' || fails=$((fails+1))
mut "M4 BackNowTarget drops the myUser == 0 test" "--- FAIL J (14,14,14)" bt \
  's/myUser == 0 && //' || fails=$((fails+1))
mut "M5 BackNowTarget drops the currentUser test" "--- FAIL J (14,15,0)" bt \
  's/ && extraUid == currentUser//' || fails=$((fails+1))
mut "M6 the receiver passes ctx instead of app" "PIN   S3" rx \
  's/ChooserActivity\.postSavingNotice\(app, uid\)/ChooserActivity.postSavingNotice(ctx, uid)/' || fails=$((fails+1))
mut "M7 postBackNowRefused builds its own Intent(uc, ...)" "PIN   S2" ch \
  's/(static void postBackNowRefused\(Context app, int uid, String body, long reconnectAt\) \{(?:(?!static void).)*?)android\.app\.PendingIntent pi = backNowTapIntent\(app, uid, reconnectAt\);/$1Intent tap = new Intent(uc, BackupNowReceiver.class); android.app.PendingIntent pi = android.app.PendingIntent.getBroadcast(uc, 0, tap, android.app.PendingIntent.FLAG_IMMUTABLE);/s' || fails=$((fails+1))
mut "M8 the receiver posts Backing up with no target user" "PIN   S4" rx \
  's/if \(uid > 0\) (ChooserActivity\.postSavingNotice)/$1/' || fails=$((fails+1))
mut "M9 decide posts the refused prompt with no target user" "PIN   S4" rx \
  's/\n\s*if \(uid <= 0\) return;[^\n]*//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
