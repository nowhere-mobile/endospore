package com.nowhere.chooser;

// NWP-20261019-12: the cases for OtaCheckWait -- the OTA-VERSIONS parse, every arm of decide(), and replaceUpToDate (run.sh).
public final class OtaCheckWaitCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static final long CAP = 30000;
    static final String OLD = "running 0.5.4 checked 1792454000 lasterr none store yes";

    static String line(long tried, int refreshing, String err) {
        return "running 0.5.4 checked 1792454000 lasterr " + err + " store yes tried_ms " + tried + " refreshing " + refreshing;
    }

    static OtaCheckWait.Versions v(long tried, boolean refreshing, String err) {
        return OtaCheckWait.parse(line(tried, refreshing ? 1 : 0, err));
    }

    static int decide(OtaCheckWait.Versions b, OtaCheckWait.Versions n, long waited) {
        return OtaCheckWait.decide(b, n, waited, CAP);
    }

    public static void main(String[] a) {
        // ---- parse ----
        OtaCheckWait.Versions p = OtaCheckWait.parse(line(1792454400123L, 1, "unreachable"));
        check("parse: a full line", p.known && p.triedMs == 1792454400123L && p.refreshing && "unreachable".equals(p.lastErr), p.triedMs);
        p = OtaCheckWait.parse(line(-1, 0, "none"));
        check("parse: never tried is known, tried -1", p.known && p.triedMs == -1 && !p.refreshing && "none".equals(p.lastErr), p.triedMs);
        check("parse: an older daemon's line is not known", !OtaCheckWait.parse(OLD).known, "known");
        check("parse: a failed read (empty) is not known", !OtaCheckWait.parse("").known, "known");
        check("parse: a null read is not known", !OtaCheckWait.parse(null).known, "known");
        check("parse: a malformed tried_ms is not known", !OtaCheckWait.parse(OLD + " tried_ms abc refreshing 0").known, "known");
        check("parse: surrounding whitespace is fine", OtaCheckWait.parse("  " + line(5, 0, "none") + "\n").triedMs == 5, "tried");

        OtaCheckWait.Versions never = v(-1, false, "none");
        OtaCheckWait.Versions old100 = v(100, false, "none");

        // ---- decide ----
        check("decide: an attempt after the tap, no error -> FRESH",
                decide(old100, v(200, false, "none"), 3000) == OtaCheckWait.FRESH, decide(old100, v(200, false, "none"), 3000));
        check("decide: first ever attempt finishes (before = never) -> FRESH",
                decide(never, v(200, false, "none"), 3000) == OtaCheckWait.FRESH, "x");
        check("decide: an attempt after the tap that failed -> CHECK_FAILED",
                decide(old100, v(200, false, "unreachable"), 3000) == OtaCheckWait.CHECK_FAILED, "x");
        check("decide: a no-store failure -> CHECK_FAILED",
                decide(old100, v(200, false, "no-store"), 3000) == OtaCheckWait.CHECK_FAILED, "x");
        check("decide: before had an attempt and now repeats it unchanged -> WAIT",
                decide(old100, v(100, false, "none"), 3000) == OtaCheckWait.WAIT, decide(old100, v(100, false, "none"), 3000));
        check("decide: unchanged, and still refreshing -> WAIT",
                decide(old100, v(100, true, "none"), 3000) == OtaCheckWait.WAIT, "x");
        check("decide: never tried, and the refresh is in flight -> WAIT",
                decide(never, v(-1, true, "none"), 3000) == OtaCheckWait.WAIT, "x");
        check("decide: never tried, and not refreshing, before the cap -> WAIT",
                decide(never, v(-1, false, "none"), 3000) == OtaCheckWait.WAIT, "x");
        check("decide: an attempt finished while another still refreshes -> WAIT before the cap",
                decide(old100, v(200, true, "none"), 3000) == OtaCheckWait.WAIT, decide(old100, v(200, true, "none"), 3000));
        check("decide: ... and its verdict at the cap (clean)",
                decide(old100, v(200, true, "none"), CAP) == OtaCheckWait.FRESH, decide(old100, v(200, true, "none"), CAP));
        check("decide: ... and its verdict at the cap (failed)",
                decide(old100, v(200, true, "unreachable"), CAP + 1) == OtaCheckWait.CHECK_FAILED, "x");
        check("decide: cap reached with nothing changed -> TIMEOUT",
                decide(old100, v(100, false, "none"), CAP) == OtaCheckWait.TIMEOUT, decide(old100, v(100, false, "none"), CAP));
        check("decide: cap reached, nothing changed, still refreshing -> TIMEOUT",
                decide(old100, v(100, true, "none"), CAP + 5000) == OtaCheckWait.TIMEOUT, "x");
        check("decide: cap reached, never tried -> TIMEOUT",
                decide(never, v(-1, true, "none"), CAP) == OtaCheckWait.TIMEOUT, "x");
        check("decide: one tick under the cap still waits",
                decide(old100, v(100, false, "none"), CAP - 1) == OtaCheckWait.WAIT, "x");
        check("decide: no tried_ms key in now -> LEGACY",
                decide(old100, OtaCheckWait.parse(OLD), 3000) == OtaCheckWait.LEGACY, "x");
        check("decide: an empty read in now -> LEGACY, even past the cap",
                decide(old100, OtaCheckWait.parse(""), CAP + 1) == OtaCheckWait.LEGACY, "x");
        check("decide: no tried_ms key in before (an empty read) while now has an attempt -> LEGACY",
                decide(OtaCheckWait.parse(""), v(200, false, "none"), 3000) == OtaCheckWait.LEGACY,
                decide(OtaCheckWait.parse(""), v(200, false, "none"), 3000));
        check("decide: an older daemon on both reads -> LEGACY",
                decide(OtaCheckWait.parse(OLD), OtaCheckWait.parse(OLD), 0) == OtaCheckWait.LEGACY, "x");

        // ---- replaceUpToDate ----
        int[] all = { OtaCheckWait.LEGACY, OtaCheckWait.WAIT, OtaCheckWait.FRESH, OtaCheckWait.CHECK_FAILED, OtaCheckWait.TIMEOUT };
        String[] heads = { "NONE", "AVAIL", "UNKNOWN", "FAILED", "NOSTORE", "DOWNLOADING", "" };
        for (int d : all) {
            for (String h : heads) {
                boolean want = d == OtaCheckWait.CHECK_FAILED && ("NONE".equals(h) || "UNKNOWN".equals(h));
                check("replaceUpToDate(" + d + ", '" + h + "') == " + want, OtaCheckWait.replaceUpToDate(d, h) == want, !want);
            }
        }

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails != 0) System.exit(1);
    }
}
