package com.nowhere.chooser;

/**
 * What "What's using space" shows of the session's kept storage count, lifted out of ProfileActivity so a JDK can run
 * it. java.* only. NWP-20261120-09; decision of record h48 #6 in docs/product-decisions.md (DECIDED 2026-10-30): the
 * screen shows the last count with its age ("Counted 12 min ago · counting again…") at any age within the session, a
 * fresh count starts every time the screen opens, and it replaces the shown figure when it lands.
 *
 * The wire is core/agent/storage_count.go's:
 * <pre>
 *   GET-STORAGE-BREAKDOWN-CACHED  NONE | PENDING &lt;running 0|1&gt; &lt;lastErr&gt;
 *                               | OK &lt;nbytes&gt; &lt;countedAt unix&gt; &lt;running 0|1&gt; &lt;lastErr&gt;\n&lt;json&gt;
 * </pre>
 * lastErr is "none" or the first field of the last failed count. A failed count keeps the old figure.
 */
final class StorageCountView {
    private StorageCountView() {}

    /** Cached.kind. UNKNOWN: an older daemon's "ERR ...", "" from a failed read, or a header that does not parse. */
    static final int NONE = 0, PENDING = 1, OK = 2, UNKNOWN = 3;

    /** next()'s steps. */
    static final int LEGACY = 0, NO_SESSION = 1, WAIT = 2, RENDER = 3, DONE = 4, FAILED = 5;

    /** One parsed CACHED header line. */
    static final class Cached {
        final int kind;
        final long nbytes, countedAtSec;
        final boolean running;
        final String lastErr;

        Cached(int kind, long nbytes, long countedAtSec, boolean running, String lastErr) {
            this.kind = kind; this.nbytes = nbytes; this.countedAtSec = countedAtSec;
            this.running = running; this.lastErr = lastErr;
        }
    }

    private static final Cached UNKNOWN_HEADER = new Cached(UNKNOWN, 0, 0, false, "");

    /** Parse the CACHED header line. It never throws: anything it does not recognise is UNKNOWN. A countedAt of 0 or
     *  less is UNKNOWN too, because the screen could never show it as newer than "nothing shown yet" (0). */
    static Cached parse(String headerLine) {
        if (headerLine == null) return UNKNOWN_HEADER;
        String t = headerLine.trim();
        if (t.isEmpty()) return UNKNOWN_HEADER;
        String[] f = t.split(" +");
        try {
            if (f.length == 1 && "NONE".equals(f[0])) return new Cached(NONE, 0, 0, false, "");
            if (f.length == 3 && "PENDING".equals(f[0]) && isFlag(f[1])) {
                return new Cached(PENDING, 0, 0, "1".equals(f[1]), f[2]);
            }
            if (f.length == 5 && "OK".equals(f[0]) && isFlag(f[3])) {
                long n = Long.parseLong(f[1]);
                long at = Long.parseLong(f[2]);
                if (n < 0 || at <= 0) return UNKNOWN_HEADER;
                return new Cached(OK, n, at, "1".equals(f[3]), f[4]);
            }
        } catch (NumberFormatException e) {
            return UNKNOWN_HEADER;
        }
        return UNKNOWN_HEADER;
    }

    private static boolean isFlag(String s) { return "0".equals(s) || "1".equals(s); }

    /** The age line under the local total. Whole minutes, rounded down, at any age; under a minute (and a clock that
     *  reads before countedAt) it says so in words. While a fresh count runs, " · counting again…" follows. */
    static String ageLine(long nowSec, long countedAtSec, boolean running) {
        long d = nowSec - countedAtSec;
        String s = d < 60 ? "Counted less than a minute ago" : "Counted " + (d / 60) + " min ago";
        return running ? s + " · counting again…" : s;
    }

    /** What the screen does with a CACHED reply, given the countedAt it already shows (0 = nothing shown yet). */
    static int next(Cached c, long shownCountedAtSec) {
        if (c == null || c.kind == UNKNOWN) return LEGACY; // an older daemon or a failed read: today's walk
        if (c.kind == NONE) return NO_SESSION;
        if (c.kind == PENDING && c.running) return WAIT; // the first count of the session runs
        if (c.kind == PENDING && "none".equals(c.lastErr)) return LEGACY; // no count ran and none runs: do not poll forever
        if (c.kind == PENDING) return FAILED; // the last count failed: today's failure texts, keyed on its token
        if (c.countedAtSec > shownCountedAtSec) return RENDER; // a count the screen does not show yet
        if (c.running) return WAIT; // the fresh count still runs
        return DONE; // nothing newer will come; a failed fresh count keeps the shown figure
    }
}
