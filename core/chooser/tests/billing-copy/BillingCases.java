// NWP-20261016-39: the cases for the Profile screen's plan summary (formatBilling, formatCoverage), run against
// Lifted (run.sh). Every case asserts a distinguishing substring AND the absence of the competing arm's.
public final class BillingCases {
    static int fails = 0, runs = 0;
    static final long GIB = 1L << 30;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) { fails++; System.out.println("  FAIL  " + name + "  got: " + got); }
    }

    static String s(CharSequence c) { return c == null ? null : c.toString(); }

    static void has(String name, CharSequence got, String... want) {
        String g = s(got);
        for (String w : want) check(name + " has [" + w + "]", g != null && g.contains(w), g);
    }

    static void lacks(String name, CharSequence got, String... no) {
        String g = s(got);
        for (String w : no) check(name + " lacks [" + w + "]", g != null && !g.contains(w), g);
    }

    static Lifted with(String sessionType) { Lifted l = new Lifted(); l.sessionType = sessionType; return l; }

    static long epochNow(long epochsec) { return System.currentTimeMillis() / 1000L / epochsec; }

    static final String FREE = "On the free tier";
    static final String OLD = "On the free tier — this profile roams within the free allowance, at no cost. "
            + "Start a plan to store more, or to keep it longer.";
    static final String OVER = "over the 1 GB free allowance";
    static final String RO = "Read-only";
    static final String KEEP = "you can keep adding up to 1 GB";
    static final String NOT_ADD = "but not add";
    static final String SERVER = "plan is active for this profile on our servers";

    public static void main(String[] a) {
        java.util.Locale.setDefault(java.util.Locale.US);
        java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("UTC"));
        final long DAY = 86400, WEEK = 604800;
        final long now = epochNow(DAY);
        Lifted st = with("STORED");

        // --- no local wallet: -1 is NOT 0, and the server's plan is stated as fact
        CharSequence r = st.formatBilling(null, -1);
        has("null/-1 STORED", r, FREE); lacks("null/-1 STORED", r, SERVER, "Not stored yet");
        r = st.formatBilling("NONE", -1);
        has("NONE/-1 STORED", r, FREE);
        r = st.formatBilling(null, 0);
        has("null/0 STORED", r, FREE); lacks("null/0 STORED", r, SERVER);
        r = st.formatBilling(null, 10 * GIB);
        has("null/10GiB", r, "10 GB " + SERVER, "You don't need to buy anything"); lacks("null/10GiB", r, FREE);
        r = st.formatBilling(null, 512L << 20);
        has("null/512MiB", r, "A plan is active"); lacks("null/512MiB", r, "0 GB", FREE);
        r = with("LOCAL").formatBilling(null, -1);
        has("null/LOCAL", r, "Not stored yet"); lacks("null/LOCAL", r, FREE, SERVER);

        // --- funded but not activated is not "Not leased yet"
        r = st.formatBilling("OK through=0 pending=1 plangb=10 periods=3", -1);
        has("pending", r, "10 GB plan · 3 months", "Purchased — starting shortly");
        lacks("pending", r, "Not leased yet", "Another purchase is waiting", "A purchase is waiting");
        r = st.formatBilling("OK through=0 pending=1 plangb=10 periods=1", -1);
        has("pending 1 period", r, "10 GB plan · 1 month\n");
        r = st.formatBilling("OK through=0", -1);
        has("through=0", r, "Not leased yet"); lacks("through=0", r, "Purchased — starting shortly");

        // --- live plan
        String ep = " epochsec=86400";
        r = st.formatBilling("OK through=" + (now + 5) + ep + " plangb=10", 10 * GIB);
        has("live +5", r, "10 GB plan · 5 days left", "Expires ", "Your plan lives on this phone");
        lacks("live +5", r, "Our servers don't show", "expired", "waiting to start");
        r = st.formatBilling("OK through=" + now + ep, 10 * GIB);
        has("live today", r, "Plan · expires today"); lacks("live today", r, "days left", "1 day left");
        r = st.formatBilling("OK through=" + (now + 1) + ep, 10 * GIB);
        has("live +1", r, "1 day left"); lacks("live +1", r, "1 days left");

        // --- NWP-20261117-22: the first paint (entitled -1) states a live term in the past tense only, until the
        // gateway answers (an unreachable gateway keeps -1): no days left, no "Expires", no wallet sentence
        final String MOVING = "Your plan is moving to your new passphrase";
        final String NOSHOW = "don't show this plan";
        r = st.formatBilling("OK through=" + (now + 5) + ep + " plangb=10", -1);
        has("first paint live", r, "10 GB plan — bought through");
        lacks("first paint live", r, "days left", "Expires ", "Your plan lives on this phone", "Our servers don't show", MOVING);
        r = st.formatBilling("OK through=" + now + ep, -1);
        has("first paint today", r, "Plan — bought through"); lacks("first paint today", r, "expires today", "days left");
        r = st.formatBilling("OK through=" + (now + 5) + ep + " plangb=10 pending=1", -1);
        has("first paint + pending", r, "Another purchase is waiting to start", "bought through");
        lacks("first paint + pending", r, "days left", "A purchase is waiting");
        r = st.formatBilling("OK through=" + (now - 3) + ep, -1);
        has("first paint expired", r, "Plan expired"); lacks("first paint expired", r, "bought through");

        // --- the server does not show this plan: only for a live term and entitled == 0
        r = st.formatBilling("OK through=" + (now + 5) + ep + " plangb=10 deadline=" + (now + 40), 0);
        has("live, entitled 0", r, "Our servers don't show this plan", "bought through", "Your data is kept until");
        lacks("live, entitled 0", r, "Your plan lives on this phone", "days left");
        r = st.formatBilling("OK through=" + (now + 5) + ep, -1);
        lacks("live, entitled -1", r, "Our servers don't show");
        r = st.formatBilling("OK through=" + (now + 5) + ep, 10 * GIB);
        lacks("live, entitled>0", r, "Our servers don't show"); has("live, entitled>0", r, "5 days left");
        r = st.formatBilling("OK through=" + (now - 3) + ep, 0);
        has("expired, entitled 0", r, "Plan expired"); lacks("expired, entitled 0", r, "Our servers don't show");
        has("expired, entitled 0 wallet line", r, "Your plan lives on this phone");

        // --- expired
        r = st.formatBilling("OK through=" + (now - 3) + ep + " deadline=" + (now + 20), -1);
        has("expired", r, "Plan expired", "Your data is kept until");
        lacks("expired", r, "days left", "waiting to start", RO, KEEP);
        r = st.formatBilling("OK through=" + (now - 3) + ep, -1);
        lacks("expired, no deadline", r, "Your data is kept until");

        // --- a purchase waiting behind a live or an expired term
        r = st.formatBilling("OK through=" + (now + 5) + ep + " pending=1", -1);
        has("live + pending", r, "Another purchase is waiting to start"); lacks("live + pending", r, "A purchase is waiting");
        r = st.formatBilling("OK through=" + (now - 3) + ep + " credit=5", -1);
        has("expired + credit", r, "A purchase is waiting to start"); lacks("expired + credit", r, "Another purchase");
        r = st.formatBilling("OK through=" + (now + 5) + ep + " credit=5", -1);
        lacks("live + credit, no pending", r, "waiting to start");

        // --- epochsec absent: the old weekly 604800
        long wk = epochNow(WEEK);
        r = st.formatBilling("OK through=" + (wk + 3), 10 * GIB);
        has("epochsec absent", r, "3 days left"); lacks("epochsec absent", r, "Plan expired");
        r = st.formatBilling("OK through=" + (wk + 3) + " epochsec=604800", 10 * GIB);
        has("epochsec explicit weekly", r, "3 days left");

        // --- a non-numeric token is ignored
        r = st.formatBilling("OK through=" + (now + 5) + ep + " plangb=ten periods=x pending=?", 10 * GIB);
        has("non-numeric", r, "Plan · 5 days left"); lacks("non-numeric", r, "GB plan", "waiting to start");

        // --- formatCoverage
        r = st.formatCoverage("OK covered=10737418240 entitled=0");
        has("coverage free", r, "Plan covers 10.0 GB", "(free tier)");
        r = st.formatCoverage("OK covered=10737418240 entitled=10737418240");
        has("coverage paid", r, "Plan covers 10.0 GB"); lacks("coverage paid", r, "(free tier)");
        r = st.formatCoverage("OK covered=1073741824 entitled=-1");
        has("coverage entitled -1", r, "(free tier)");
        check("coverage covered=0", st.formatCoverage("OK covered=0 entitled=0") == null, "");
        check("coverage no covered", st.formatCoverage("OK entitled=5") == null, "");
        check("coverage non-OK", st.formatCoverage("UNKNOWN") == null, "");
        check("coverage null", st.formatCoverage(null) == null, "");

        // --- NWP-20261028-04: the free allowance is the whole profile, 1 GB (docs/product-decisions.md 2026-10-19 item 4)
        final long over = (long) (1.2 * GIB);
        check("free tier not measured", OLD.equals(Lifted.freeTierLine(-1, 0)), Lifted.freeTierLine(-1, 0));
        check("free tier zero", OLD.equals(Lifted.freeTierLine(0, 0)), Lifted.freeTierLine(0, 0));
        check("free tier exactly 1 GiB", OLD.equals(Lifted.freeTierLine(GIB, 0)), Lifted.freeTierLine(GIB, 0));
        check("free tier 1000000001 B is under 1 GiB", OLD.equals(Lifted.freeTierLine(1000000001L, 0)),
                Lifted.freeTierLine(1000000001L, 0));
        r = Lifted.freeTierLine(GIB + 1, 0);
        has("free tier 1 GiB + 1", r, FREE, OVER, "Free up space", "start a plan"); lacks("free tier 1 GiB + 1", r, "at no cost");
        r = Lifted.freeTierLine(over, 0);
        has("free tier 1.2 GiB", r, "holds 1.2 GB", OVER);
        r = Lifted.freeTierLine(over, -1);
        has("free tier 1.2 GiB first paint", r, "holds 1.2 GB", "more than the 1 GB free allowance");
        lacks("free tier 1.2 GiB first paint", r, "free tier", "at no cost", "plan");
        st = with("STORED"); st.occupiedBytes = over;
        r = st.formatBilling("NONE", 0);
        has("billing over", r, OVER, "1.2 GB"); lacks("billing over", r, "at no cost");
        r = st.formatBilling(null, -1);
        has("billing over first paint", r, "more than the 1 GB free allowance"); lacks("billing over first paint", r, "free tier", "plan");
        r = st.formatBilling(null, 10 * GIB);
        has("billing entitled > 0 unchanged", r, "10 GB ", SERVER); lacks("billing entitled > 0 unchanged", r, OVER, "more than the 1 GB");
        r = st.formatBilling("OK through=" + (now + 5) + ep + " plangb=10", 10 * GIB);
        has("live wallet unchanged", r, "10 GB plan · 5 days left"); lacks("live wallet unchanged", r, OVER, "more than the 1 GB");
        st = with("LOCAL"); st.occupiedBytes = over;
        r = st.formatBilling(null, 0);
        has("local unchanged", r, "Not stored yet"); lacks("local unchanged", r, OVER);
        st = with("STORED"); st.occupiedBytes = GIB;
        check("billing at 1 GiB", OLD.equals(s(st.formatBilling("NONE", 0))), st.formatBilling("NONE", 0));

        // --- NWP-20261103-10 (Q082): "Read-only" only over the free allowance
        check("add line unmeasured", "".equals(Lifted.addAllowanceLine(-1)), Lifted.addAllowanceLine(-1));
        for (long u : new long[] {0, 300L << 20, GIB}) {
            has("add line " + u, Lifted.addAllowanceLine(u), KEEP); lacks("add line " + u, Lifted.addAllowanceLine(u), RO);
        }
        for (long u : new long[] {GIB + 1, 2 * GIB}) {
            has("add line " + u, Lifted.addAllowanceLine(u), RO, NOT_ADD); lacks("add line " + u, Lifted.addAllowanceLine(u), KEEP);
        }
        final String lapsed = "OK through=" + (now - 3) + ep + " deadline=" + (now + 20);
        final String stranger = "OK through=" + (now + 5) + ep + " plangb=10 deadline=" + (now + 40);
        st = with("STORED"); st.occupiedBytes = 2 * GIB;
        r = st.formatBilling(lapsed, -1);
        has("expired 2 GiB", r, "Plan expired", RO, "Your data is kept until"); lacks("expired 2 GiB", r, KEEP);
        r = st.formatBilling(stranger, 0);
        has("entitled 0, 2 GiB", r, "Our servers don't show this plan", "only the free allowance is covering your data", RO);
        lacks("entitled 0, 2 GiB", r, KEEP);
        r = st.formatBilling(stranger, -1);
        lacks("live, 2 GiB", r, RO, KEEP);
        st = with("STORED"); st.occupiedBytes = 300L << 20;
        r = st.formatBilling(lapsed, -1);
        has("expired 300 MiB", r, "Plan expired", KEEP, "Your data is kept until"); lacks("expired 300 MiB", r, RO, NOT_ADD);
        r = st.formatBilling(stranger, 0);
        has("entitled 0, 300 MiB", r, "Our servers don't show this plan", "only the free allowance is covering your data", KEEP);
        lacks("entitled 0, 300 MiB", r, RO, NOT_ADD);
        r = st.formatBilling(stranger, -1);
        lacks("live, 300 MiB", r, RO, KEEP);
        st = with("STORED");
        r = st.formatBilling(lapsed, -1);
        has("expired unmeasured", r, "Plan expired", "Your data is kept until"); lacks("expired unmeasured", r, RO, KEEP, "\n\nYour data");
        r = st.formatBilling(stranger, 0);
        has("entitled 0, unmeasured", r, "Our servers don't show this plan", "only the free allowance is covering your data");
        lacks("entitled 0, unmeasured", r, RO, KEEP, NOT_ADD, "\n\nYour data");

        // NWP-20261103-11 (Q147): a rebind outstanding inside the cooldown (moving=) is shown as moving.
        st = with("STORED"); st.occupiedBytes = 300L << 20;
        r = st.formatBilling(stranger + " moving=" + (now * DAY), 0);
        has("moving, entitled 0", r, MOVING, "up to 7 days", "free allowance covers your data", "bought through", KEEP, "Your data is kept until");
        lacks("moving, entitled 0", r, NOSHOW, "Until that's sorted");
        st.occupiedBytes = 2 * GIB;
        r = st.formatBilling(stranger + " moving=" + (now * DAY), 0);
        has("moving, entitled 0, 2 GiB", r, MOVING, RO); lacks("moving, entitled 0, 2 GiB", r, NOSHOW, KEEP);
        r = st.formatBilling(stranger, 0);
        has("moving absent", r, NOSHOW); lacks("moving absent", r, MOVING);
        r = st.formatBilling(stranger + " moving=soon", 0);
        has("moving unparsable", r, NOSHOW); lacks("moving unparsable", r, MOVING);
        r = st.formatBilling(stranger + " moving=" + (now * DAY), -1);
        has("moving, entitled -1 (first paint)", r, "bought through");
        lacks("moving, entitled -1 (first paint)", r, "days left", MOVING, NOSHOW);
        r = st.formatBilling(stranger + " moving=" + (now * DAY), 5 * GIB);
        has("moving, entitled > 0", r, "5 days left"); lacks("moving, entitled > 0", r, MOVING, NOSHOW);

        // NWP-20261120-10 (h48 #9): the plans in run order, only in the live arm the gateway has answered (entitled > 0).
        final String runOrder = "OK credit=0 through=" + (now + 100) + ep + " plangb=50 plans=50:" + (now + 100)
                + ",10:" + (now + 190);
        r = st.formatBilling(runOrder, 50 * GIB);
        has("plans, entitled > 0", r, "50 GB plan", "100 days left", "\n50 GB to ", ", then 10 GB to ");
        r = st.formatBilling(runOrder, -1);
        has("plans, entitled -1 (first paint)", r, "bought through"); lacks("plans, entitled -1 (first paint)", r, "50 GB to ");
        r = st.formatBilling(runOrder, 0);
        has("plans, entitled 0", r, "bought through"); lacks("plans, entitled 0", r, "50 GB to ");
        r = st.formatBilling("OK credit=0 through=" + (now + 100) + ep + " plangb=50", 50 * GIB);
        has("no plans, entitled > 0", r, "100 days left"); lacks("no plans, entitled > 0", r, " GB to ");

        System.out.println(runs + " checks, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
