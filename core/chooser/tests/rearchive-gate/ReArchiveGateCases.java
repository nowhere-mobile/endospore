package com.nowhere.chooser;

/** NWP-20261102-15: ReArchiveReceiver's archive verdict, NWP-20261120-12: when its next sweep runs (armAt), and
 *  NWP-20261122-10: an app that holds a job (holdsJob) is kept, and visible and foreground-service time count as use.
 *  Compiled with ReArchiveGate ALONE (java.* only). */
public class ReArchiveGateCases {
    static final long DAY = 86_400_000L;
    static final long IDLE = 3 * DAY;
    static final long NOW = 100 * DAY;
    static final long H = 3_600_000L;
    static int runs = 0, fails = 0;

    static void check(String name, boolean ok, String got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static final long OLD = NOW - 10 * DAY; // well past IDLE
    static final String P = "com.foo";

    static boolean a(long idle, long used, long vis, long fgs, long update, boolean job) {
        return ReArchiveGate.archive(NOW, idle, used, vis, fgs, update, job);
    }

    static boolean held(String ime, String vpn, String a11y, String listeners, java.util.Set<String> roles) {
        return ReArchiveGate.holdsJob(P, ime, vpn, a11y, listeners, roles);
    }

    /** The job alone keeps the app: the same old times with no job archive it. */
    static void kept(String name, boolean job) {
        boolean control = a(IDLE, OLD, OLD, OLD, OLD, false);
        boolean verdict = a(IDLE, OLD, OLD, OLD, OLD, job);
        check(name, job && control && !verdict, "held=" + job + " control=" + control + " archived=" + verdict);
    }

    static long at(long pending) { return ReArchiveGate.armAt(pending, NOW, NOW + H); }

    public static void main(String[] args) {
        check("Never idle 0 keeps even with last 0", !a(0, 0, 0, 0, 0, false), "archived");
        check("Never idle -1 keeps even with last 0", !a(-1, 0, 0, 0, 0, false), "archived");
        check("fresh materialise, never used, is kept", !a(IDLE, 0, 0, 0, NOW - IDLE + 1, false), "archived");
        check("used 1 ms inside the window is kept", !a(IDLE, NOW - IDLE + 1, 0, 0, 0, false), "archived");
        check("exactly idle since last is archived", a(IDLE, NOW - IDLE, 0, 0, NOW - IDLE, false), "kept");
        check("both old is archived", a(IDLE, NOW - 10 * DAY, 0, 0, NOW - 9 * DAY, false), "kept");
        check("lastUpdate later than lastUsed wins", !a(IDLE, NOW - 10 * DAY, 0, 0, NOW - DAY, false), "archived");
        check("usage absent falls back to the floor",
                !a(IDLE, 0, 0, 0, NOW - DAY, false) && a(IDLE, 0, 0, 0, NOW - 4 * DAY, false),
                "fresh=" + !a(IDLE, 0, 0, 0, NOW - DAY, false));
        check("clock behind the floor is kept", !a(IDLE, 0, 0, 0, NOW + DAY, false), "archived");
        kept("the current keyboard is kept past idle", held("com.foo/.Ime", null, null, null, null));
        kept("the always-on VPN is kept past idle", held(null, "com.foo", null, null, null));
        kept("an accessibility service in a list of three is kept past idle",
                held(null, null, "com.a/.A:com.foo/com.foo.Svc:com.b/.B", null, null));
        kept("a notification listener is kept past idle", held(null, null, null, "com.foo/.Listen", null));
        kept("a role holder is kept past idle", held(null, null, null, null, java.util.Set.of("com.bar", "com.foo")));
        check("a held job keeps an app past idle",
                a(IDLE, OLD, OLD, OLD, OLD, false) && !a(IDLE, OLD, OLD, OLD, OLD, true), "archived");
        check("com.foo.bar does not hold for com.foo",
                !held("com.foo.bar/.Ime", "com.foo.bar", "com.foo.bar/.A", "com.foo.bar/.L",
                        java.util.Set.of("com.foo.bar")), "held");
        check("com.foo2 does not hold for com.foo",
                !held("com.foo2/.Ime", "com.foo2", "com.foo2/.A", "com.foo2/.L", java.util.Set.of("com.foo2")), "held");
        check("a component without a slash holds nothing", !held("com.foo", null, "com.foo", "com.foo", null), "held");
        check("null sources hold nothing", !held(null, null, null, null, null)
                && !ReArchiveGate.holdsJob(null, "com.foo/.Ime", "com.foo", null, null, null), "held");
        check("empty sources hold nothing", !held("", "", "", "", java.util.Collections.emptySet())
                && !held("::", null, ":", ":", null) && !ReArchiveGate.holdsJob("", "/.Ime", "", ":/.A", "/.L", null),
                "held");
        check("visible inside the window is kept", !a(IDLE, OLD, NOW - IDLE + 1, OLD, OLD, false), "archived");
        check("a foreground service inside the window is kept", !a(IDLE, OLD, OLD, NOW - IDLE + 1, OLD, false),
                "archived");
        check("all four times old and no job is archived", a(IDLE, OLD, OLD, OLD, OLD, false), "kept");
        check("Never idle 0 keeps an app with no job", !a(0, OLD, OLD, OLD, OLD, false), "archived");
        check("override 0 uses the profile value", ReArchiveGate.effectiveIdle(0, IDLE) == IDLE,
                "" + ReArchiveGate.effectiveIdle(0, IDLE));
        check("override negative uses the profile value",
                ReArchiveGate.effectiveIdle(-5, IDLE) == IDLE && ReArchiveGate.effectiveIdle(-5, 0) == 0,
                ReArchiveGate.effectiveIdle(-5, IDLE) + "/" + ReArchiveGate.effectiveIdle(-5, 0));
        check("override beats the profile's Never", ReArchiveGate.effectiveIdle(DAY, 0) == DAY,
                "" + ReArchiveGate.effectiveIdle(DAY, 0));
        check("override beats the profile's value", ReArchiveGate.effectiveIdle(DAY, IDLE) == DAY,
                "" + ReArchiveGate.effectiveIdle(DAY, IDLE));
        check("armAt no pending gives want", at(0) == NOW + H, "" + at(0));
        check("armAt pending before want is kept", at(NOW + 10 * 60_000L) == NOW + 10 * 60_000L,
                "" + at(NOW + 10 * 60_000L));
        check("armAt pending equal to want is kept", at(NOW + H) == NOW + H, "" + at(NOW + H));
        check("armAt pending after want gives want", at(NOW + 2 * H) == NOW + H, "" + at(NOW + 2 * H));
        check("armAt pending in the past is not pending", at(NOW - 1) == NOW + H, "" + at(NOW - 1));
        check("armAt pending equal to now is not pending", at(NOW) == NOW + H, "" + at(NOW));
        if (fails == 0) System.out.println("PASS " + runs + " cases");
        System.exit(fails == 0 ? 0 : 1);
    }
}
