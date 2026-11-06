#!/usr/bin/env bash
# test-crash-records-java.sh [--mutate] -- NWP-20261128-17 (Q121), backlog row "Profile crash reaching the gate
# (frankel) — and the gate reporter could say nothing about it". Compiles core/chooser's CrashRecords.java against
# android stubs and EXECUTES its cases: the pure filter (crash tags only, the session start time, the header UID of
# another Android user, the newest five, 4096 chars each) and the DropBox reader (ok, denied and error, the rolling
# window of the newest five in a crash loop, read through every record of a tag). Then source checks: reportRequestJson sends
# crash_access, the manifest asks PEEK_DROPBOX_DATA and not READ_LOGS, CrashRecords logs and writes nothing, and the
# gate's report JSON holds no crash text.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must FAIL with its named case: a mutant that does
# not apply (INERT) or fails some other way (BROKEN) counts as a failure, never a pass.
#
#   bash test-crash-records-java.sh            # the cases
#   bash test-crash-records-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-crash-records-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
command -v perl >/dev/null 2>&1 || { echo "test-crash-records-java: FAIL -- the source checks need perl, and there is none; this suite did NOT run" >&2; exit 2; }
CR="$ROOT/core/chooser/src/com/nowhere/chooser/CrashRecords.java"
PA="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
MF="$ROOT/core/chooser/AndroidManifest.xml"
CA="$ROOT/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"

# The android.* members CrashRecords uses, as stubs, plus android.util.Log so a mutant that logs still compiles.
STUBS="$W/stubs"
mkdir -p "$STUBS/android/content" "$STUBS/android/os" "$STUBS/android/util"
cat > "$STUBS/android/content/Context.java" <<'EOF'
package android.content;
public class Context {
    public static final java.util.Map<Class<?>, Object> SERVICES = new java.util.HashMap<>();
    public <T> T getSystemService(Class<T> c) { return c.cast(SERVICES.get(c)); }
}
EOF
cat > "$STUBS/android/os/UserHandle.java" <<'EOF'
package android.os;
public final class UserHandle {
    private final int id;
    public UserHandle(int id) { this.id = id; }
    public int getIdentifier() { return id; }
}
EOF
cat > "$STUBS/android/os/Process.java" <<'EOF'
package android.os;
public final class Process {
    public static UserHandle ME = new UserHandle(10);
    public static UserHandle myUserHandle() { return ME; }
}
EOF
cat > "$STUBS/android/os/UserManager.java" <<'EOF'
package android.os;
public class UserManager {
    public static long CREATED;
    public static RuntimeException THROW;
    public long getUserCreationTime(UserHandle h) { if (THROW != null) throw THROW; return CREATED; }
}
EOF
cat > "$STUBS/android/os/DropBoxManager.java" <<'EOF'
package android.os;
public class DropBoxManager {
    public static final java.util.List<Entry> STORE = new java.util.ArrayList<>(); // in time order
    public static final java.util.List<Entry> SERVED = new java.util.ArrayList<>();
    public static final java.util.Map<String, Integer> CALLS = new java.util.HashMap<>();
    public static RuntimeException THROW;
    public static void reset() { STORE.clear(); SERVED.clear(); CALLS.clear(); THROW = null; }
    public Entry getNextEntry(String tag, long t) {
        CALLS.merge(tag, 1, Integer::sum);
        if (THROW != null) throw THROW;
        for (Entry e : STORE) if (e.tag.equals(tag) && e.time > t) { SERVED.add(e); return e; }
        return null;
    }
    public static class Entry implements java.io.Closeable {
        final String tag; final long time; final String text; public boolean closed;
        public Entry(String tag, long time, String text) { this.tag = tag; this.time = time; this.text = text; }
        public String getTag() { return tag; }
        public long getTimeMillis() { return time; }
        public String getText(int max) { return text == null ? null : text.length() > max ? text.substring(0, max) : text; }
        @Override public void close() { closed = true; }
    }
}
EOF
cat > "$STUBS/android/util/Log.java" <<'EOF'
package android.util;
public final class Log { public static int d(String t, String m) { return 0; } }
EOF

cat > "$W/CrashRecordsCases.java" <<'EOF'
package com.nowhere.chooser;

import android.content.Context;
import android.os.DropBoxManager;
import android.os.UserManager;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class CrashRecordsCases {
    static int bad = 0;
    static void ok(String id, boolean c, String why) {
        if (c) System.out.println("PASS " + id); else { System.out.println("FAIL " + id + ": " + why); bad++; }
    }
    static CrashRecords.Entry e(String tag, long t, String text) { return new CrashRecords.Entry(tag, t, text); }
    static String body(String s) { return s.substring(s.indexOf('\n') + 1); }

    static CrashRecords.Result read(long created) {
        UserManager.CREATED = created;
        try { return CrashRecords.read(new Context()); }
        catch (Throwable t) { return new CrashRecords.Result("THREW " + t, new ArrayList<>()); }
    }
    static void services(boolean withDropBox) {
        Context.SERVICES.clear();
        Context.SERVICES.put(UserManager.class, new UserManager());
        if (withDropBox) Context.SERVICES.put(DropBoxManager.class, new DropBoxManager());
        UserManager.THROW = null;
        DropBoxManager.reset();
    }

    public static void main(String[] a) {
        final long S = 1_000_000L, NOW = 2_000_000L;
        List<String> r;

        // C1 the session start time.
        r = CrashRecords.select(Arrays.asList(e("data_app_crash", S - 1, "before")), S, 10, NOW);
        ok("C1a", r.isEmpty(), "a crash before the session start was kept: " + r);
        r = CrashRecords.select(Arrays.asList(e("data_app_crash", S, "at")), S, 10, NOW);
        ok("C1b", r.size() == 1, "a crash at the session start was dropped");

        // C2 the tags.
        r = CrashRecords.select(Arrays.asList(e("data_app_anr", S + 1, "anr"), e("SYSTEM_BOOT", S + 2, "boot")), S, 10, NOW);
        ok("C2a", r.isEmpty(), "a non-crash tag was kept: " + r);
        for (String tag : CrashRecords.TAGS) {
            r = CrashRecords.select(Arrays.asList(e(tag, S + 1, "x")), S, 10, NOW);
            ok("C2b " + tag, r.size() == 1 && r.get(0).startsWith(tag + " age_s="), "a crash tag was dropped: " + r);
        }

        // C3 the header UID.
        r = CrashRecords.select(Arrays.asList(e("data_app_crash", S + 1, "Process: p\nUID: 1110123\n\nstack")), S, 10, NOW);
        ok("C3a", r.isEmpty(), "a crash of user 11 was kept for user 10: " + r);
        r = CrashRecords.select(Arrays.asList(e("data_app_crash", S + 1, "Process: p\nUID: 1010123\n\nstack")), S, 10, NOW);
        ok("C3b", r.size() == 1, "a crash of this user was dropped");
        r = CrashRecords.select(Arrays.asList(e("data_app_crash", S + 1, "Process: p\n\nstack")), S, 10, NOW);
        ok("C3c", r.size() == 1, "a crash with no UID line was dropped");
        r = CrashRecords.select(Arrays.asList(e("data_app_crash", S + 1, "Process: p\n\nUID: 1110123\nstack")), S, 10, NOW);
        ok("C3d", r.size() == 1, "a UID line in the body counted as the header's");

        // C4 the newest five, newest first, whatever the input order.
        List<CrashRecords.Entry> eight = new ArrayList<>();
        for (int i : new int[] {3, 8, 1, 6, 2, 7, 5, 4}) eight.add(e("data_app_crash", S + i, "c" + i));
        r = CrashRecords.select(eight, S, 10, NOW);
        List<String> bodies = new ArrayList<>();
        for (String s : r) bodies.add(body(s));
        ok("C4", bodies.equals(Arrays.asList("c8", "c7", "c6", "c5", "c4")), "want c8..c4, got " + bodies);

        // C5 the 4096-char cut and the age line.
        StringBuilder big = new StringBuilder();
        while (big.length() < 10000) big.append('z');
        r = CrashRecords.select(Arrays.asList(e("data_app_crash", NOW - 7500, big.toString())), S, 10, NOW);
        ok("C5", r.size() == 1 && r.get(0).startsWith("data_app_crash age_s=7\n") && body(r.get(0)).length() == 4096,
                "want age_s=7 and a 4096-char body, got " + (r.isEmpty() ? "nothing" : r.get(0).substring(0, 30) + ".. " + body(r.get(0)).length()));

        CrashRecords.Result res;
        // C6 a DropBox SecurityException is "denied".
        services(true);
        DropBoxManager.THROW = new SecurityException("no PEEK_DROPBOX_DATA");
        res = read(S);
        ok("C6", "denied".equals(res.access) && res.crashes.isEmpty(), "want denied and no crashes, got " + res.access);

        // C7 every other failure is "error", and read never throws.
        services(true);
        DropBoxManager.THROW = new IllegalStateException("boom");
        res = read(S);
        ok("C7a", "error".equals(res.access) && res.crashes.isEmpty(), "DropBox IllegalStateException: want error, got " + res.access);
        services(true);
        UserManager.THROW = new SecurityException("no user");
        res = read(S);
        ok("C7b", "error".equals(res.access), "UserManager SecurityException: want error, got " + res.access);
        services(false);
        res = read(S);
        ok("C7c", "error".equals(res.access), "no DropBoxManager: want error, got " + res.access);
        Context.SERVICES.clear();
        res = read(S);
        ok("C7d", "error".equals(res.access), "no UserManager: want error, got " + res.access);

        // C8 the happy path: only the crashes after the creation time, every served entry closed.
        services(true);
        DropBoxManager.STORE.add(new DropBoxManager.Entry("data_app_crash", S - 50, "old"));
        DropBoxManager.STORE.add(new DropBoxManager.Entry("data_app_crash", S + 10, "new-1"));
        DropBoxManager.STORE.add(new DropBoxManager.Entry("system_app_native_crash", S + 20, "new-2"));
        res = read(S);
        boolean closed = !DropBoxManager.SERVED.isEmpty();
        for (DropBoxManager.Entry x : DropBoxManager.SERVED) closed &= x.closed;
        ok("C8", "ok".equals(res.access) && res.crashes.size() == 2 && body(res.crashes.get(0)).equals("new-2")
                && body(res.crashes.get(1)).equals("new-1") && closed, "want ok, new-2 then new-1, all closed; got "
                + res.access + " " + res.crashes + " closed=" + closed);

        // C9 a crash loop: the newest five, not the first five read.
        services(true);
        for (int i = 1; i <= 40; i++) DropBoxManager.STORE.add(new DropBoxManager.Entry("data_app_crash", S + 1000L * i, "crash-" + i));
        res = read(S);
        bodies = new ArrayList<>();
        for (String s : res.crashes) bodies.add(body(s));
        ok("C9", "ok".equals(res.access) && bodies.equals(Arrays.asList("crash-40", "crash-39", "crash-38", "crash-37", "crash-36")),
                "want crash-40..crash-36, got " + res.access + " " + bodies);

        // C10 a long crash loop: every record is read, and the newest five are kept, not five of the first read.
        services(true);
        for (int i = 1; i <= 600; i++) DropBoxManager.STORE.add(new DropBoxManager.Entry("data_app_crash", S + i, "n-" + i));
        res = read(S);
        bodies = new ArrayList<>();
        for (String s : res.crashes) bodies.add(body(s));
        Integer calls = DropBoxManager.CALLS.get("data_app_crash");
        ok("C10", "ok".equals(res.access) && calls != null && calls == 601
                && bodies.equals(Arrays.asList("n-600", "n-599", "n-598", "n-597", "n-596")),
                "want 601 reads and n-600..n-596, got " + calls + " reads, " + res.access + " " + bodies);

        // C11 600 earlier crashes of another user do not hide this user's latest crash.
        services(true);
        for (int i = 1; i <= 600; i++) DropBoxManager.STORE.add(new DropBoxManager.Entry("data_app_crash", S + i, "Process: p\nUID: 1110123\n\nother-" + i));
        DropBoxManager.STORE.add(new DropBoxManager.Entry("data_app_crash", S + 601, "Process: p\nUID: 1010123\n\nmine"));
        res = read(S);
        bodies = new ArrayList<>();
        for (String s : res.crashes) bodies.add(body(s));
        ok("C11", "ok".equals(res.access) && bodies.size() == 1 && bodies.get(0).endsWith("\n\nmine"),
                "want only this user's latest crash, got " + res.access + " " + bodies);

        System.exit(bad == 0 ? 0 : 1);
    }
}
EOF

# method <file> <signature fragment> -> from the signature to the first line closing it at the class's method indent.
method() { awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }

# check <CrashRecords.java> <ProfileActivity.java> <AndroidManifest.xml> <ChooserActivity.java>
check() {
  local d rc=0 m
  d=$(mktemp -d -p "$W") || return 2
  mkdir -p "$d/out"
  if ! "$JAVAC" -nowarn -d "$d/out" -sourcepath "$STUBS" "$1" "$W/CrashRecordsCases.java" \
       $(find "$STUBS" -name '*.java') >"$d/javac.log" 2>&1; then
    cat "$d/javac.log"; echo "FAIL compile"; rm -rf "$d"; return 1
  fi
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.CrashRecordsCases || rc=1
  rm -rf "$d"
  m=$(method "$2" 'private String reportRequestJson(')
  if [ -n "$m" ] && [[ "$m" == *'CrashRecords.read(this)'* ]] && [[ "$m" == *'o.put("crash_access", cr.access)'* ]]; then
    echo "PASS S1"; else echo "FAIL S1: reportRequestJson does not read CrashRecords and put crash_access"; rc=1; fi
  if grep -q '<uses-permission android:name="android.permission.PEEK_DROPBOX_DATA"/>' "$3" \
     && ! grep -q 'android.permission.READ_LOGS' "$3"; then
    echo "PASS S2"; else echo "FAIL S2: the manifest must ask PEEK_DROPBOX_DATA and not READ_LOGS"; rc=1; fi
  if ! grep -Eq '(^|[^A-Za-z])Log\.|FileOutputStream|FileWriter' "$1"; then
    echo "PASS S3"; else echo "FAIL S3: CrashRecords logs or writes a file"; rc=1; fi
  m=$(method "$4" 'private String gateReportJson(')
  if [ -z "$m" ]; then echo "FAIL S4: gateReportJson not found"; rc=1
  elif [[ "${m,,}" == *crash* ]]; then echo "FAIL S4: the gate's report JSON holds crash text"; rc=1
  else echo "PASS S4"; fi
  return "$rc"
}
check "$CR" "$PA" "$MF" "$CA" || { echo "FAILED"; exit 1; }
echo "== all cases passed"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <cr|pa|mf> <perl-expr> <text the failure must contain>
  local d f src cr pa mf out rc
  d=$(mktemp -d -p "$W"); cr=$CR; pa=$PA; mf=$MF
  case "$2" in cr) src=$CR ;; pa) src=$PA ;; mf) src=$MF ;; esac
  f="$d/$(basename "$src")"; cp "$src" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$src" "$f"; then echo "  INERT     $1"; return 1; fi
  case "$2" in cr) cr=$f ;; pa) pa=$f ;; mf) mf=$f ;; esac
  out=$(check "$cr" "$pa" "$mf" "$CA" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4' (rc=$rc)"; printf '%s\n' "$out" | tail -n 10; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "M1 the start-time filter removed" cr 's/\n\s*if \(e\.timeMs < sessionStartMs\) return false;//' "FAIL C1a" || fails=$((fails+1))
mut "M2 the tag filter removed" cr 's/ \|\| !TAGS\.contains\(e\.tag\)\)/)/' "FAIL C2a" || fails=$((fails+1))
mut "M3 the uid check removed" cr 's/return uid < 0 \|\| uid \/ AID_USER == myUserId;/return true;/' "FAIL C3a" || fails=$((fails+1))
mut "M4 the 4096 cap removed" cr 's/String t = e\.text\.length\(\) > MAX_CHARS \? e\.text\.substring\(0, MAX_CHARS\) : e\.text;/String t = e.text;/' "FAIL C5" || fails=$((fails+1))
mut "M5 SecurityException mapped to error" cr 's/return new Result\("denied", none\);/return new Result("error", none);/' "FAIL C6" || fails=$((fails+1))
mut "M6 the crash_access put removed" pa 's/\n\s*o\.put\("crash_access", cr\.access\);//' "FAIL S1" || fails=$((fails+1))
mut "M7 READ_LOGS added to the manifest" mf 's#(<uses-permission android:name="android\.permission\.PEEK_DROPBOX_DATA"/>\n)#$1  <uses-permission android:name="android.permission.READ_LOGS"/>\n#' "FAIL S2" || fails=$((fails+1))
mut "M8 a crash text logged" cr 's/(\n(\s*)String t = e\.text\.length\(\))/\n$2android.util.Log.d("NowhereChooser", e.text);$1/' "FAIL S3" || fails=$((fails+1))
mut "M9 the window keeps the first entries" cr 's/while \(w\.size\(\) > cap\) w\.removeFirst\(\);/while (w.size() > cap) w.removeLast();/' "FAIL C9" || fails=$((fails+1))
mut "M10 a 512-read cap per tag restored" cr 's/while \(true\) \{/for (int i = 0; i < 512; i++) {/' "FAIL C10" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
