import android.content.ContentResolver;
import android.content.Context;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** NWP-20261112-16: a read-back that did not complete is UNKNOWN, never "absent". NWP-20261123-17: a run in which a
 *  file's read-back or calendar lookup did not complete does not spend one of its tries; a failed create still does. The behavioural cases run the members
 *  run.sh lifted out of Ingest.java (class Lifted) against a stub resolver whose answer per table is programmable; the
 *  source checks read the real Ingest.java (args[0]) with comments and string/char literals stripped, for the call sites
 *  in run() that cannot be lifted on their own. Prints one line per check; exit 1 when any failed. */
public class IngestUnknownCases {
    static final String CONTACTS = "content://com.android.contacts/raw_contacts";
    static final String CALENDARS = "content://com.android.calendar/calendars";
    static final String EVENTS = "content://com.android.calendar/events";
    static int fails;

    static void check(String what, boolean ok) {
        System.out.println((ok ? "ok    " : "FAIL  ") + what);
        if (!ok) fails++;
    }

    static void eq(String what, Object want, Object got) {
        check(what + " -> " + got + (Objects.equals(want, got) ? "" : " (want " + want + ")"), Objects.equals(want, got));
    }

    static Context ctx(String uri, long answer) {
        Context c = new Context();
        c.r.answer.put(uri, answer);
        return c;
    }

    public static void main(String[] args) throws Exception {
        // ---- ingestStep: only a completed "no row" inserts; an unknown waits
        eq("ingestStep(FALSE) inserts", Lifted.STEP_INSERT, Lifted.ingestStep(Boolean.FALSE));
        eq("ingestStep(TRUE) merges", Lifted.STEP_MERGE, Lifted.ingestStep(Boolean.TRUE));
        eq("ingestStep(null) waits", Lifted.STEP_WAIT, Lifted.ingestStep(null));
        check("the three steps are distinct", Lifted.STEP_INSERT != Lifted.STEP_MERGE
                && Lifted.STEP_MERGE != Lifted.STEP_WAIT && Lifted.STEP_INSERT != Lifted.STEP_WAIT);

        // ---- contactPresence: rawContactId's answer as presence
        eq("LOOKUP_FAILED", -2L, Lifted.LOOKUP_FAILED);
        eq("contactPresence(7)", Boolean.TRUE, Lifted.contactPresence(7));
        eq("contactPresence(0)", Boolean.TRUE, Lifted.contactPresence(0));
        eq("contactPresence(-1) (completed, no row)", Boolean.FALSE, Lifted.contactPresence(-1));
        eq("contactPresence(LOOKUP_FAILED)", null, Lifted.contactPresence(Lifted.LOOKUP_FAILED));
        eq("contactPresence(-3)", null, Lifted.contactPresence(-3));

        // ---- eitherPresent: identity key + legacy key
        Boolean T = Boolean.TRUE, F = Boolean.FALSE, U = null;
        eq("eitherPresent(TRUE, TRUE)", T, Lifted.eitherPresent(T, T));
        eq("eitherPresent(TRUE, FALSE)", T, Lifted.eitherPresent(T, F));
        eq("eitherPresent(FALSE, TRUE)", T, Lifted.eitherPresent(F, T));
        eq("eitherPresent(TRUE, null)", T, Lifted.eitherPresent(T, U));
        eq("eitherPresent(null, TRUE)", T, Lifted.eitherPresent(U, T));
        eq("eitherPresent(FALSE, FALSE)", F, Lifted.eitherPresent(F, F));
        eq("eitherPresent(FALSE, null)", U, Lifted.eitherPresent(F, U));
        eq("eitherPresent(null, FALSE)", U, Lifted.eitherPresent(U, F));
        eq("eitherPresent(null, null)", U, Lifted.eitherPresent(U, U));

        // ---- rawContactId: a failed query is LOOKUP_FAILED, never -1
        eq("rawContactId, a row", 42L, Lifted.rawContactId(ctx(CONTACTS, 42), "k"));
        eq("rawContactId, completed with no row", -1L, Lifted.rawContactId(ctx(CONTACTS, ContentResolver.EMPTY), "k"));
        eq("rawContactId, null cursor", Lifted.LOOKUP_FAILED,
                Lifted.rawContactId(ctx(CONTACTS, ContentResolver.NULL), "k"));
        eq("rawContactId, the query threw", Lifted.LOOKUP_FAILED,
                Lifted.rawContactId(ctx(CONTACTS, ContentResolver.THROW), "k"));

        // ---- eventExists: a failed query is null, never false
        eq("eventExists, a row", Boolean.TRUE, Lifted.eventExists(ctx(EVENTS, 3), 1, "uid"));
        eq("eventExists, completed with no row", Boolean.FALSE,
                Lifted.eventExists(ctx(EVENTS, ContentResolver.EMPTY), 1, "uid"));
        eq("eventExists, null cursor", null, Lifted.eventExists(ctx(EVENTS, ContentResolver.NULL), 1, "uid"));
        eq("eventExists, the query threw", null, Lifted.eventExists(ctx(EVENTS, ContentResolver.THROW), 1, "uid"));

        // ---- ensureLocalCalendar: only a completed query that found nothing creates the calendar
        Context c;
        c = ctx(CALENDARS, 5);
        eq("ensureLocalCalendar, found", 5L, Lifted.ensureLocalCalendar(c));
        eq("  ... inserts", 0, c.r.inserts);
        c = ctx(CALENDARS, ContentResolver.EMPTY);
        eq("ensureLocalCalendar, completed with no row: created", 9L, Lifted.ensureLocalCalendar(c));
        eq("  ... inserts", 1, c.r.inserts);
        c = ctx(CALENDARS, ContentResolver.NULL);
        eq("ensureLocalCalendar, null cursor", Lifted.LOOKUP_FAILED, Lifted.ensureLocalCalendar(c));
        eq("  ... inserts (no second calendar)", 0, c.r.inserts);
        c = ctx(CALENDARS, ContentResolver.THROW);
        eq("ensureLocalCalendar, the query threw", Lifted.LOOKUP_FAILED, Lifted.ensureLocalCalendar(c));
        eq("  ... inserts (no second calendar)", 0, c.r.inserts);
        // NWP-20261123-17: a failed CREATE is a rejection (-1, it spends a try), not an unknown.
        check("LOOKUP_FAILED is not -1", Lifted.LOOKUP_FAILED != -1);
        c = ctx(CALENDARS, ContentResolver.EMPTY);
        c.r.insertAnswer = null;
        long created = Lifted.ensureLocalCalendar(c);
        eq("ensureLocalCalendar, the create answered null", -1L, created);
        check("  ... is not LOOKUP_FAILED", created != Lifted.LOOKUP_FAILED);
        eq("  ... inserts", 1, c.r.inserts);
        c = ctx(CALENDARS, ContentResolver.EMPTY);
        c.r.insertThrows = true;
        eq("ensureLocalCalendar, the create threw", -1L, Lifted.ensureLocalCalendar(c));
        eq("  ... inserts", 1, c.r.inserts);

        // ---- countsAsAttempt: only a run that could see the provider and still not verify spends a try
        eq("countsAsAttempt(complete, 0 unknown)", false, Lifted.countsAsAttempt(true, 0));
        eq("countsAsAttempt(complete, 2 unknown)", false, Lifted.countsAsAttempt(true, 2));
        eq("countsAsAttempt(incomplete, 0 unknown)", true, Lifted.countsAsAttempt(false, 0));
        eq("countsAsAttempt(incomplete, 1 unknown)", false, Lifted.countsAsAttempt(false, 1));

        sourceChecks(args[0]);
        System.out.println(fails == 0 ? "PASS" : fails + " check(s) FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }

    // ------------------------------------------------------------------ source checks on the real Ingest.java

    static void sourceChecks(String path) throws Exception {
        String s = strip(new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8));

        check("S1 no '!e.exists(ctx)' remains", !s.contains("!e.exists(ctx)"));
        check("S1 no 'boolean exists(' remains (the contract is Boolean)", !s.contains("boolean exists("));

        String run = body(s, "static void run(Context ctx)");
        int p1 = run.indexOf("for (Entry e : sf.entries)");
        int rv = run.indexOf("for (long wait : REVERIFY_MS)");
        int fin = run.indexOf("int present = 0;");
        int done = run.indexOf("boolean complete");
        boolean ordered = p1 >= 0 && rv > p1 && fin > rv && done > fin;
        check("run(): pass 1, re-verify and finalize found in order", ordered);
        if (ordered) {
            String pass1 = run.substring(p1, rv), reverify = run.substring(rv, fin), finalize = run.substring(fin, done);
            check("S2 pass 1 asks ingestStep", pass1.contains("int step = ingestStep(e.exists(ctx));"));
            check("S2 pass 1 inserts only on STEP_INSERT", pass1.contains("if (step == STEP_INSERT) e.insert(ctx);"));
            check("S2 pass 1 merges only on STEP_MERGE", pass1.contains("else if (step == STEP_MERGE) e.merge(ctx);"));
            check("S2 pass 1 counts the rest as unknown, for the run and the file",
                    pass1.contains("else { unknown++; sf.unknownReads++; }"));
            check("S2 pass 1 has one insert and one merge",
                    count(pass1, "e.insert(ctx)") == 1 && count(pass1, "e.merge(ctx)") == 1);
            check("S3 re-verify asks ingestStep", reverify.contains("int step = ingestStep(e.exists(ctx));"));
            check("S3 re-verify counts an unknown, never inserts on it",
                    reverify.contains("if (step == STEP_WAIT) { unknown++; sf.unknownReads++; }"));
            check("S3 re-verify inserts only on STEP_INSERT",
                    reverify.contains("else if (step == STEP_INSERT) e.insert(ctx);"));
            check("S3 re-verify has exactly one insert", count(reverify, "e.insert(ctx)") == 1);
            check("S4 finalize counts only Boolean.TRUE as present",
                    finalize.contains("if (Boolean.TRUE.equals(p)) present++;"));
            check("S4 finalize has exactly one present++", count(finalize, "present++") == 1);
        }
        check("S8 run() logs the unknown count", run.contains("if (unknown > 0)"));

        // ---- NWP-20261123-17: an unknown counts against its file, and only a counted attempt spends a try
        check("S9 run() counts an unknown in pass 1, re-verify and finalize", count(run, "unknown++") == 3);
        check("S9 every unknown++ in run() also bumps its file's unknownReads in the same branch",
                count(run, "{ unknown++; sf.unknownReads++; }") == count(run, "unknown++"));
        String tail = done < 0 ? "" : run.substring(done);
        String guard = "if (countsAsAttempt(false, sf.unknownReads))";
        String g = body(tail, guard);
        check("S10 finalize guards its try on countsAsAttempt(... sf.unknownReads)",
                Pattern.compile("if \\(countsAsAttempt\\([^()]*sf\\.unknownReads\\)\\) \\{").matcher(tail).find());
        check("S10 bumpTries is called only inside the countsAsAttempt branch",
                g.contains("bumpTries(") && count(run, "bumpTries(") == 1);
        check("S10 the MAX_TRIES settle is inside the countsAsAttempt branch",
                g.contains("if (tries >= MAX_TRIES)") && g.contains("settle(ctx, sf)"));
        String ics = body(s, "private static void parseIcsInto(");
        String neg = body(ics, "if (calId < 0)");
        int inc = neg.indexOf("if (calId == LOOKUP_FAILED) sf.unknownReads++;");
        int ret = neg.indexOf("return;");
        check("S11 parseIcsInto counts a calendar lookup that did not answer, before its return",
                inc >= 0 && ret > inc);
        check("S11 parseIcsInto increments unknownReads only under calId == LOOKUP_FAILED",
                count(ics, "unknownReads++") == 1 && count(neg, "unknownReads++") == 1);
        String caa = body(s, "static boolean countsAsAttempt(");
        check("S12 countsAsAttempt is pure", !caa.isEmpty() && !caa.contains("ctx") && !caa.contains("android.")
                && !caa.contains("Log."));

        String rci = body(s, "private static long rawContactId(");
        check("S5 rawContactId: a null cursor is LOOKUP_FAILED", rci.contains("if (c == null) return LOOKUP_FAILED;"));
        check("S5 rawContactId: its catch returns LOOKUP_FAILED",
                Pattern.compile("catch \\(Throwable t\\) \\{ return LOOKUP_FAILED; \\}").matcher(rci).find());
        check("S5 rawContactId: no 'return -1;' in a catch",
                !Pattern.compile("catch \\([^)]*\\) \\{[^}]*return -1;").matcher(rci).find());

        String ev = body(s, "private static Boolean eventExists(");
        check("S5 eventExists: no 'return false;'", !ev.contains("return false;"));
        check("S5 eventExists: a null cursor and a throw are null",
                ev.contains("if (c == null) return null;")
                        && Pattern.compile("catch \\(Throwable t\\) \\{ return null; \\}").matcher(ev).find());

        String cal = body(s, "private static long ensureLocalCalendar(");
        int ins = cal.indexOf(".insert(");
        String before = ins < 0 ? "" : cal.substring(0, ins);
        check("S6 ensureLocalCalendar: a null cursor returns LOOKUP_FAILED before the create",
                Pattern.compile("if \\(c == null\\) \\{[^{}]*return LOOKUP_FAILED; \\}").matcher(before).find());
        check("S6 ensureLocalCalendar: a failed query returns LOOKUP_FAILED before the create",
                Pattern.compile("catch \\(Throwable t\\) \\{[^{}]*return LOOKUP_FAILED; \\}").matcher(before).find());
        check("S6 ensureLocalCalendar: a failed create returns -1",
                ins >= 0 && cal.substring(ins).contains("return u == null ? -1 :"));

        String vcf = body(s, "private static void parseVcfInto(");
        check("S7 the contact entry asks contactPresence(rawContactId(ctx, key))",
                vcf.contains("contactPresence(rawContactId(ctx, key))"));
        check("S7 the contact entry combines its two keys with eitherPresent", vcf.contains("eitherPresent("));
        check("S7 rawContactExists is gone", !s.contains("rawContactExists"));
    }

    static int count(String hay, String needle) {
        int n = 0;
        for (int i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + needle.length())) n++;
        return n;
    }

    /** The text from sig to the brace closing its body ("" when sig is absent: every check on it then fails). */
    static String body(String s, String sig) {
        int i = s.indexOf(sig);
        if (i < 0) return "";
        int j = s.indexOf('{', i), depth = 0;
        for (int k = j; k >= 0 && k < s.length(); k++) {
            char ch = s.charAt(k);
            if (ch == '{') depth++;
            else if (ch == '}' && --depth == 0) return s.substring(i, k + 1);
        }
        return "";
    }

    /** Comments removed, string and char literals emptied ("" / ''), every run of whitespace one space. */
    static String strip(String in) {
        StringBuilder out = new StringBuilder(in.length());
        int n = in.length();
        for (int i = 0; i < n; i++) {
            char ch = in.charAt(i);
            char nx = i + 1 < n ? in.charAt(i + 1) : 0;
            if (ch == '/' && nx == '/') {
                while (i < n && in.charAt(i) != '\n') i++;
                out.append(' ');
            } else if (ch == '/' && nx == '*') {
                i += 2;
                while (i + 1 < n && !(in.charAt(i) == '*' && in.charAt(i + 1) == '/')) i++;
                i++;
                out.append(' ');
            } else if (ch == '"' || ch == '\'') {
                i++;
                while (i < n && in.charAt(i) != ch) { if (in.charAt(i) == '\\') i++; i++; }
                out.append(ch).append(ch);
            } else {
                out.append(ch);
            }
        }
        Matcher m = Pattern.compile("\\s+").matcher(out);
        return m.replaceAll(" ");
    }
}
