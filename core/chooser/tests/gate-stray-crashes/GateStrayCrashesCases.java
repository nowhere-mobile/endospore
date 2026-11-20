import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** NWP-20261210-24: the evidence a gate issue report carries for the backlog row "Stray broadcasts wake providers INTO
 *  a user whose CE storage is already gone, and they crash on the gate (NWP-20260826-10 tail)". Runs GateStrayCrashes's
 *  pure members (lifted, executed: C1-C9), with records parsed by the real process() and CrashRecords.headerUid, then
 *  pins the reads that cannot run without Android (P1-P5), on source with its comments stripped.
 *  args: <chooser java dir>. Exits 1 on any failed case or pin. */
public final class GateStrayCrashesCases {
    private static int fails = 0;

    static final String[] KEYS = {
        "stray_crash_calendar", "stray_crash_media", "stray_crash_gone", "stray_crash_stopped", "stray_crash_nouid",
    };
    static final long BOOT = 1_800_000_000_000L;
    // Users 10 and 11 exist and are stopped, 12 is the running session; 13 is gone.
    static final Set<Integer> EXISTING = new HashSet<>(Arrays.asList(10, 11, 12));
    static final Set<Integer> RUNNING = new HashSet<>(Arrays.asList(12));

    private static void ok(boolean cond, String what) {
        if (cond) {
            System.out.println("  ok    " + what);
        } else {
            System.out.println("  FAIL  " + what);
            fails++;
        }
    }

    private static void eq(String what, Object got, Object want) {
        boolean same = String.valueOf(want).equals(String.valueOf(got));
        ok(same, what + (same ? "" : ": got [" + got + "], want [" + want + "]"));
    }

    /** A DropBox record's text: a Process header, a UID header when uid >= 0, an empty line, then a stack. */
    static String text(String proc, int uid) {
        return "Process: " + proc + "\nPID: 4242\n" + (uid >= 0 ? "UID: " + uid + "\n" : "")
                + "Flags: 0x38c8be45\n\nandroid.database.sqlite.SQLiteCantOpenDatabaseException: unable to open\n";
    }

    /** Records as put() keeps them: each text reduced to its process, its header uid and its time. */
    static final class Recs {
        final List<String> procs = new ArrayList<>();
        final List<Long> times = new ArrayList<>();
        final List<Integer> uids = new ArrayList<>();
        Recs add(String text, long time) {
            procs.add(GateStrayCrashes.process(text));
            uids.add(CrashRecords.headerUid(text));
            times.add(time);
            return this;
        }
        Recs add(String proc, int uid, long time) { return add(text(proc, uid), time); }
        LinkedHashMap<String, String> tally() {
            long[] t = new long[times.size()];
            int[] u = new int[uids.size()];
            for (int i = 0; i < t.length; i++) { t[i] = times.get(i); u[i] = uids.get(i); }
            return GateStrayCrashes.tally(procs.toArray(new String[0]), t, u, BOOT, EXISTING, RUNNING);
        }
    }

    static String counts(int cal, int media, int gone, int stopped, int nouid) {
        return "{stray_crash_calendar=" + cal + ", stray_crash_media=" + media + ", stray_crash_gone=" + gone
                + ", stray_crash_stopped=" + stopped + ", stray_crash_nouid=" + nouid + "}";
    }

    static final String CAL = "com.android.providers.calendar", MEDIA = "android.process.media";
    static final int GONE_CAL = 13 * 100000 + 10088, GONE_MEDIA = 13 * 100000 + 10069;
    static final int STOPPED_MEDIA = 10 * 100000 + 10069, RUNNING_CAL = 12 * 100000 + 10088, U0_MEDIA = 10069;

    /** src with its // and block comments removed; string and char literals are kept as they are. */
    static String strip(String src) {
        StringBuilder b = new StringBuilder();
        int n = src.length();
        for (int i = 0; i < n; i++) {
            char c = src.charAt(i);
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && src.charAt(j) != c) { if (src.charAt(j) == '\\') j++; j++; }
                b.append(src, i, Math.min(j + 1, n));
                i = j;
            } else if (c == '/' && i + 1 < n && src.charAt(i + 1) == '/') {
                while (i < n && src.charAt(i) != '\n') i++;
                b.append('\n');
            } else if (c == '/' && i + 1 < n && src.charAt(i + 1) == '*') {
                int j = src.indexOf("*/", i + 2);
                i = j < 0 ? n : j + 1;
                b.append(' ');
            } else {
                b.append(c);
            }
        }
        return b.toString();
    }

    /** The body of the method whose signature contains sig, through its closing brace; "" when absent. */
    private static String body(String src, String sig) {
        int i = src.indexOf(sig);
        if (i < 0) return "";
        int depth = 0;
        for (int j = src.indexOf('{', i); j >= 0 && j < src.length(); j++) {
            char c = src.charAt(j);
            if (c == '{') depth++;
            if (c == '}' && --depth == 0) return src.substring(i, j + 1);
        }
        return "";
    }

    /** Every "<call>(...)" in src, from the call to its closing parenthesis. */
    private static List<String> calls(String src, String call) {
        List<String> out = new ArrayList<>();
        for (int i = src.indexOf(call); i >= 0; i = src.indexOf(call, i + 1)) {
            int depth = 0;
            for (int j = src.indexOf('(', i); j >= 0 && j < src.length(); j++) {
                char c = src.charAt(j);
                if (c == '(') depth++;
                if (c == ')' && --depth == 0) { out.add(src.substring(i, j + 1)); break; }
            }
        }
        return out;
    }

    private static int count(String hay, String needle) {
        int n = 0;
        for (int i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + needle.length())) n++;
        return n;
    }

    private static String read(String p) throws Exception {
        return new String(Files.readAllBytes(Paths.get(p)), StandardCharsets.UTF_8);
    }

    public static void main(String[] a) throws Exception {
        String dir = a[0];
        String gsc = strip(read(dir + "/GateStrayCrashes.java"));
        String ca = strip(read(dir + "/ChooserActivity.java"));

        System.out.println("-- (a) the members, executed");
        eq("C0 CAL", GateStrayCrashes.CAL, CAL);
        eq("C0 MEDIA", GateStrayCrashes.MEDIA, MEDIA);

        eq("C1 a gone user's calendar and media records",
                new Recs().add(CAL, GONE_CAL, BOOT + 5).add(MEDIA, GONE_MEDIA, BOOT + 6).tally(), counts(1, 1, 2, 0, 0));
        eq("C1 userState of a gone user", GateStrayCrashes.userState(GONE_CAL, EXISTING, RUNNING), "gone");

        eq("C2 a stopped user's media record counts as stopped",
                new Recs().add(MEDIA, STOPPED_MEDIA, BOOT + 5).tally(), counts(0, 1, 0, 1, 0));
        eq("C2 userState of a stopped user", GateStrayCrashes.userState(STOPPED_MEDIA, EXISTING, RUNNING), "stopped");

        eq("C3 a running user's record and a user-0 record count nowhere",
                new Recs().add(CAL, RUNNING_CAL, BOOT + 5).add(MEDIA, U0_MEDIA, BOOT + 6).tally(), counts(0, 0, 0, 0, 0));
        eq("C3 userState of the running user", GateStrayCrashes.userState(RUNNING_CAL, EXISTING, RUNNING), null);
        eq("C3 userState of user 0", GateStrayCrashes.userState(U0_MEDIA, EXISTING, RUNNING), null);

        eq("C4 a record before bootMs counts nowhere",
                new Recs().add(CAL, GONE_CAL, BOOT - 1).tally(), counts(0, 0, 0, 0, 0));
        eq("C4 a record at bootMs counts",
                new Recs().add(CAL, GONE_CAL, BOOT).tally(), counts(1, 0, 1, 0, 0));

        eq("C5 any other process and the near misses count nowhere",
                new Recs().add("com.example.app", GONE_CAL, BOOT + 5).add("android.process.media2", GONE_MEDIA, BOOT + 6)
                        .add("com.android.providers.calendar.x", GONE_CAL, BOOT + 7)
                        .add("com.android.providers", GONE_CAL, BOOT + 8).tally(), counts(0, 0, 0, 0, 0));
        eq("C5 code(calendar)", GateStrayCrashes.code(CAL), "calendar");
        eq("C5 code(media)", GateStrayCrashes.code(MEDIA), "media");
        eq("C5 code(media2)", GateStrayCrashes.code("android.process.media2"), null);
        eq("C5 code(calendar.x)", GateStrayCrashes.code("com.android.providers.calendar.x"), null);
        eq("C5 code(null)", GateStrayCrashes.code(null), null);

        eq("C6 no UID line -> nouid only",
                new Recs().add(CAL, -1, BOOT + 5).tally(), counts(0, 0, 0, 0, 1));
        eq("C6 userState of no uid", GateStrayCrashes.userState(-1, EXISTING, RUNNING), "nouid");

        Recs eleven = new Recs();
        for (int i = 0; i < 11; i++) eleven.add(CAL, GONE_CAL, BOOT + i);
        eq("C7 eleven records -> 10+", eleven.tally(), counts(0, 0, 0, 0, 0).replace("calendar=0", "calendar=10+")
                .replace("gone=0", "gone=10+"));
        eq("C7 bucket 0", GateStrayCrashes.bucket(0), "0");
        eq("C7 bucket 9", GateStrayCrashes.bucket(9), "9");
        eq("C7 bucket 10", GateStrayCrashes.bucket(10), "10+");
        eq("C7 bucket 11", GateStrayCrashes.bucket(11), "10+");

        Pattern val = Pattern.compile("^([0-9]|10\\+)$");
        for (Recs r : new Recs[]{new Recs(), eleven, new Recs().add(CAL, GONE_CAL, BOOT).add(MEDIA, -1, BOOT)}) {
            LinkedHashMap<String, String> m = r.tally();
            eq("C8 the key set is exactly the five keys, in order", new ArrayList<>(m.keySet()), Arrays.asList(KEYS));
            boolean all = true;
            for (String v : m.values()) all &= v != null && val.matcher(v).matches();
            ok(all, "C8 every value matches ^([0-9]|10\\+)$: " + m.values());
        }

        eq("C9 process: trimmed", GateStrayCrashes.process("Process:   " + MEDIA + "  \nUID: 1\n\n"), MEDIA);
        eq("C9 process: the first header", GateStrayCrashes.process("Process: " + CAL + "\nProcess: x\n"), CAL);
        eq("C9 process: none before the empty line", GateStrayCrashes.process("PID: 1\n\nProcess: " + CAL + "\n"), null);
        eq("C9 process: CRLF", GateStrayCrashes.process("PID: 1\r\nProcess: " + CAL + "\r\n\r\nx"), CAL);
        eq("C9 process: no header", GateStrayCrashes.process("PID: 1\nUID: 2\n"), null);
        eq("C9 process: null", GateStrayCrashes.process(null), null);

        System.out.println("-- (b) the reads, pinned in source (comments stripped)");
        String gate = body(ca, "private String gateReportJson(");
        int gne = gate.indexOf("GateNoticeEvidence.put(this, st);");
        int call = gate.indexOf("GateStrayCrashes.put(this, st);");
        ok(gne >= 0 && call > gne && count(gate, "GateStrayCrashes.put(") == 1,
                "P1 gateReportJson calls GateStrayCrashes.put(this, st) once, after GateNoticeEvidence.put");

        String put = body(gsc, "static void put(");
        ok(!put.isEmpty(), "P2 GateStrayCrashes holds static void put(");
        int denied = put.indexOf("\"denied\"");
        int c = denied < 0 ? -1 : put.lastIndexOf("catch (", denied);
        ok(count(put, "\"denied\"") == 1 && c >= 0 && put.startsWith("catch (SecurityException ", c),
                "P2 put() writes \"denied\" once, and only from a SecurityException catch");
        int dbTry = c < 0 ? -1 : put.lastIndexOf("try {", put.indexOf("getNextEntry("));
        ok(c > 0 && put.indexOf("getSecondaryUsers(") >= 0 && put.indexOf("getSecondaryUsers(") < dbTry
                        && put.indexOf("getNextEntry(") > dbTry && put.indexOf("getNextEntry(") < c
                        && count(put, "catch (SecurityException") == 1,
                "P2 the SecurityException catch guards the DropBox reads only, not the user read");

        for (String w : new String[]{"android.util.Log", "Log.", "FileOutputStream", "FileWriter", "Files.write",
                "openFileOutput", "System.out", "System.err", "printStackTrace"})
            ok(!gsc.contains(w), "P3 the class neither logs nor writes a file: no [" + w + "]");
        List<String> allowed = Arrays.asList(
                "st.put(k, v)",
                "putQuiet(st, \"gate_crash_access\", access)",
                "putQuiet(st, k, counts == null ? \"unreadable\" : counts.get(k))");
        List<String> writes = new ArrayList<>(calls(gsc, "st.put("));
        writes.addAll(calls(gsc, "putQuiet(st, "));
        boolean only = !writes.isEmpty();
        for (String w : writes) if (!allowed.contains(w)) { only = false; System.out.println("        " + w); }
        ok(only, "P3 every write to st is a key and a fixed value or a bucketed count: " + writes.size() + " found");
        boolean fixed = true;
        List<String> ws = calls(put, "write(st, ");
        for (String w : ws)
            if (!w.matches("write\\(st, \"(ok|denied|error)\", (null|tally\\(pa, ta, ua, bootMs, existing, running\\))\\)")) {
                fixed = false;
                System.out.println("        " + w);
            }
        ok(fixed && ws.size() >= 3, "P3 put() writes only a fixed access and null or the tally: " + ws.size() + " found");
        Matcher tx = Pattern.compile("\\btext\\b").matcher(put);
        int texts = 0;
        while (tx.find()) texts++;
        ok(texts == 3 && put.contains("String text = e.getText(CrashRecords.MAX_CHARS);")
                        && put.contains("p = process(text);") && put.contains("uid = CrashRecords.headerUid(text);"),
                "P3 the record text is read, reduced to its process and uid, and used nowhere else (" + texts + " uses)");
        ok(put.contains("procs.add(code(p) == null ? null : p);"), "P3 put() keeps no other process's name");

        ok(put.contains("for (String tag : CrashRecords.TAGS)"), "P4 put() iterates CrashRecords.TAGS");

        ok(put.contains("long t = bootMs - 1;"), "P5 each tag is read from bootMs - 1");
        ok(put.contains("for (int n = 0; n < MAX_READ; n++)") && gsc.contains("static final int MAX_READ = 200;"),
                "P5 at most 200 entries per tag");
        ok(put.contains("} finally {\n                            e.close();\n                        }"),
                "P5 every entry is closed in finally");
        ok(put.contains("if (time <= t) break;") && put.indexOf("if (time <= t) break;") < put.indexOf("t = time;")
                        && put.indexOf("t = time;") < put.indexOf("procs.add("),
                "P5 a read that cannot advance stops before it adds an entry");
        ok(put.contains("System.currentTimeMillis() - android.os.SystemClock.elapsedRealtime()"),
                "P5 bootMs is wall time minus the time since boot");
        ok(put.contains("isUserRunning(uh)") && put.contains("getSecondaryUsers(new android.content.ComponentName(ctx, AdminReceiver.class))"),
                "P5 the users are read as GateAlarmReceiver reads them");

        if (fails > 0) {
            System.out.println(fails + " FAILED");
            System.exit(1);
        }
        System.out.println("all passed");
    }
}
