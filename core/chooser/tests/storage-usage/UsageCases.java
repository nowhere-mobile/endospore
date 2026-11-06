// NWP-20261011-21: the cases for the chooser's pure GET-USAGE reply helpers, run against Lifted (run.sh).
public final class UsageCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static final String SESSION = "Couldn't read this — this phone has no record of the signed-in session. "
            + "Try again in a moment.";
    static final String INCOMPLETE = "Couldn't read this — the reply was incomplete.";

    public static void main(String[] a) {
        // ---- usageNoAnswer: null = render through formatUsage exactly as before ----
        check("OK bytes=1024 has a number", Lifted.usageNoAnswer("OK bytes=1024") == null, Lifted.usageNoAnswer("OK bytes=1024"));
        check("OK bytes=0 is a genuine zero, not a failure", Lifted.usageNoAnswer("OK bytes=0") == null,
                Lifted.usageNoAnswer("OK bytes=0"));
        check("OK bytes=N with the wire newline", Lifted.usageNoAnswer("OK bytes=1024\n") == null,
                Lifted.usageNoAnswer("OK bytes=1024\n"));
        check("OK alone is incomplete", INCOMPLETE.equals(Lifted.usageNoAnswer("OK")), Lifted.usageNoAnswer("OK"));
        check("OK bytes=garbage is incomplete", INCOMPLETE.equals(Lifted.usageNoAnswer("OK bytes=lots")),
                Lifted.usageNoAnswer("OK bytes=lots"));
        check("OK bytes=-1 is incomplete (formatUsage dashes it)", INCOMPLETE.equals(Lifted.usageNoAnswer("OK bytes=-1")),
                Lifted.usageNoAnswer("OK bytes=-1"));
        check("NONE names the missing session record", SESSION.equals(Lifted.usageNoAnswer("NONE")), Lifted.usageNoAnswer("NONE"));
        check("NONE with the wire newline", SESSION.equals(Lifted.usageNoAnswer("NONE\n")), Lifted.usageNoAnswer("NONE\n"));
        check("LOCAL keeps today's behaviour", Lifted.usageNoAnswer("LOCAL") == null, Lifted.usageNoAnswer("LOCAL"));
        check("null keeps today's behaviour", Lifted.usageNoAnswer(null) == null, Lifted.usageNoAnswer(null));
        check("empty keeps today's behaviour", Lifted.usageNoAnswer("") == null, Lifted.usageNoAnswer(""));
        check("UNMEASURED is its own arm, not this helper's", Lifted.usageNoAnswer("UNMEASURED") == null,
                Lifted.usageNoAnswer("UNMEASURED"));
        check("an unknown reply keeps today's behaviour", Lifted.usageNoAnswer("ERR") == null, Lifted.usageNoAnswer("ERR"));
        // Blind login: the reason is about THIS session only, never about which profiles exist.
        for (String r : new String[] { SESSION, INCOMPLETE }) {
            String l = r.toLowerCase(java.util.Locale.ROOT);
            check("no profile-existence wording: " + r, !l.contains("profile") && !l.contains("account")
                    && !l.contains("exist") && !l.contains("found"), r);
        }

        // ---- usageReason (NWP-20261019-18): the one decision both screens make ----
        final String BUSY = "the phone was busy and didn't answer in time";
        final String DOWN = "the phone's background service isn't responding";
        final String UNMEASURED = "Couldn't measure this on this phone \u2014 sign out and sign in again, then try once more.";
        check("usageReason: a usable OK renders the figure", Lifted.usageReason("OK bytes=1024", null) == null,
                Lifted.usageReason("OK bytes=1024", null));
        check("usageReason: a timeout names the busy phone",
                ("Couldn't read this \u2014 " + BUSY + ".").equals(Lifted.usageReason("", BUSY)), Lifted.usageReason("", BUSY));
        check("usageReason: an unreachable daemon names the service",
                ("Couldn't read this \u2014 " + DOWN + ".").equals(Lifted.usageReason("", DOWN)), Lifted.usageReason("", DOWN));
        check("usageReason: UNMEASURED has its own sentence",
                UNMEASURED.equals(Lifted.usageReason("UNMEASURED heads=3", null)), Lifted.usageReason("UNMEASURED heads=3", null));
        check("usageReason: NONE falls to usageNoAnswer", SESSION.equals(Lifted.usageReason("NONE", null)),
                Lifted.usageReason("NONE", null));
        check("usageReason: an OK without bytes= is incomplete", INCOMPLETE.equals(Lifted.usageReason("OK", null)),
                Lifted.usageReason("OK", null));

        // ---- humanBytes: the figure the OK arm renders ----
        check("humanBytes 1024", "1 KB".equals(Lifted.humanBytes(1024)), Lifted.humanBytes(1024));
        check("humanBytes 0", "0 B".equals(Lifted.humanBytes(0)), Lifted.humanBytes(0));
        check("humanBytes 5 MB", "5 MB".equals(Lifted.humanBytes(5L << 20)), Lifted.humanBytes(5L << 20));
        check("humanBytes 1.5 GB", "1.5 GB".equals(Lifted.humanBytes(3L << 29)), Lifted.humanBytes(3L << 29));

        // ---- plansFootprintNote (NWP-20261014-34): byte-pinned ----
        String tail = ". A plan smaller than that is full from the start: you can't add more until you delete "
                + "something or choose a larger plan.";
        String e12 = "OK used=" + (12L << 30) + " free=0 entitled=" + (10L << 30) + " covered=" + (10L << 30) + " credit=0";
        check("note: 12 GB used, above a 10 GB plan", ("This profile stores 12.0 GB" + tail).equals(Lifted.plansFootprintNote(e12)),
                Lifted.plansFootprintNote(e12));
        check("note: 3 GB used, below 10 GB", ("This profile stores 3.0 GB" + tail).equals(Lifted.plansFootprintNote("OK used=" + (3L << 30) + " free=1")),
                Lifted.plansFootprintNote("OK used=" + (3L << 30) + " free=1"));
        check("note: used=0 states 0 B", ("This profile stores 0 B" + tail).equals(Lifted.plansFootprintNote("OK used=0 free=0")),
                Lifted.plansFootprintNote("OK used=0 free=0"));
        check("note: wire newline", ("This profile stores 5 MB" + tail).equals(Lifted.plansFootprintNote("OK used=" + (5L << 20) + "\n")),
                Lifted.plansFootprintNote("OK used=" + (5L << 20) + "\n"));
        for (String r : new String[] { null, "", "NONE", "NONE\n", "NONE used=1024", "LOCAL used=1024", "UNKNOWN used=1024", "LOCAL", "UNKNOWN", "UNKNOWN\n", "ERR",
                "OK", "OK free=1 covered=2", "OK used=lots", "OK used=", "OK used=-5", "used=1024", "ok used=1024" }) {
            check("note: no line for " + r, Lifted.plansFootprintNote(r) == null, Lifted.plansFootprintNote(r));
        }
        String lw = Lifted.plansFootprintNote(e12).toLowerCase(java.util.Locale.ROOT);
        check("note: avoids the claim words", !lw.contains("safe") && !lw.contains("secure") && !lw.contains("protect")
                && !lw.contains("privacy"), lw);

        // ---- formatHeadroom + planWarning (NWP-20261014-35): warn above 80% of covered, "full" past 100% ----
        long cov = 1000;
        String[] hl = new String[5];
        long[] us = { 799, 800, 801, 1000, 1001 };
        String[] wantHead = { "", "", " · nearly full", " · nearly full", " · full" };
        for (int i = 0; i < us.length; i++) {
            String e = "OK used=" + us[i] + " free=0 entitled=" + cov + " covered=" + cov + " credit=0";
            String h = String.valueOf(Lifted.formatHeadroom(e, false));
            check("headroom at used=" + us[i] + " of 1000", h.endsWith(" used" + wantHead[i]), h);
            check("headroom full wins at used=" + us[i], (us[i] > cov) == h.endsWith(" · full") && !h.contains("nearly full · full"), h);
        }
        check("headroom: covered=0 says nothing", Lifted.formatHeadroom("OK used=900 covered=0", false) == null, "");
        check("headroom: manage suffix follows the warning",
                String.valueOf(Lifted.formatHeadroom("OK used=900 covered=1000", true)).endsWith(" · nearly full   Manage ›"), "");
        String pw = "You've used 81% of your plan. Delete something or choose a larger plan before it fills.";
        check("warn: 79% silent", Lifted.planWarning("OK used=790 covered=1000") == null, Lifted.planWarning("OK used=790 covered=1000"));
        check("warn: 80% silent", Lifted.planWarning("OK used=800 covered=1000") == null, Lifted.planWarning("OK used=800 covered=1000"));
        check("warn: 81% speaks", pw.equals(Lifted.planWarning("OK used=810 covered=1000")), Lifted.planWarning("OK used=810 covered=1000"));
        check("warn: 100% says 100", String.valueOf(Lifted.planWarning("OK used=1000 covered=1000\n")).contains("used 100% of"), "");
        check("warn: 101% still speaks", String.valueOf(Lifted.planWarning("OK used=1010 covered=1000")).contains("used 101% of"), "");
        for (String r : new String[] { null, "", "NONE", "LOCAL", "UNKNOWN", "ERR", "OK", "OK used=900", "OK covered=1000",
                "OK used=900 covered=0", "OK used=lots covered=10", "OK used=-1 covered=10", "ok used=900 covered=1000" }) {
            check("warn: nothing for " + r, Lifted.planWarning(r) == null, Lifted.planWarning(r));
        }

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
