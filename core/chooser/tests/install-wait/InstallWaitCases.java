package com.nowhere.chooser;

/** Cases for InstallWait.await on SIMULATED time -- nothing sleeps (NWP-20261022-10). The fakes' rules:
 *  - The clock is a long {@code now} starting at 0.
 *  - The latch has an optional fire time F. {@code await(ms)} returns true and sets now = max(now, F) when
 *    F <= now + ms; otherwise it sets now += ms and returns false.
 *  - The session is alive while now < its end time.
 *  - The codePath answers its "before" value while now < its change time, and its "after" value from then on.
 *  - Iteration cap: the latch throws IllegalStateException on its 101st await, so a mutant that never returns FAILS
 *    instead of hanging.
 *  Exit 0 when every case passes, 1 otherwise. */
public class InstallWaitCases {
    static final long NEVER = Long.MAX_VALUE;

    static final class Sim {
        long now = 0;
        Long fire = null;
        long sessionEnd = NEVER;
        String before = null, after = null;
        long changeAt = NEVER;
        int awaits = 0, ticks = 0;

        InstallWait.Latch latch() {
            return ms -> {
                if (++awaits > 100) throw new IllegalStateException("iteration cap: more than 100 awaits");
                if (fire != null && fire <= now + ms) { now = Math.max(now, fire); return true; }
                now += ms;
                return false;
            };
        }
        InstallWait.Session session() { return () -> now < sessionEnd; }
        InstallWait.CodePath path() { return () -> now < changeAt ? before : after; }
        InstallWait.Clock clock() { return () -> now; }
        InstallWait.Tick tick() { return () -> ticks++; }

        InstallWait.Outcome run() throws InterruptedException {
            return InstallWait.await(latch(), session(), path(), before, clock(), tick());
        }
    }

    static int failed = 0;

    static void check(String name, boolean ok, String detail) {
        if (ok) System.out.println("PASS " + name);
        else { System.out.println("FAIL " + name + ": " + detail); failed++; }
    }

    interface Setup { void apply(Sim s); }

    static void run(String name, Setup setup, InstallWait.Outcome want, long wantAwaits, long wantTicks, long wantNow) {
        Sim s = new Sim();
        setup.apply(s);
        try {
            InstallWait.Outcome got = s.run();
            boolean ok = got == want && (wantAwaits < 0 || s.awaits == wantAwaits)
                    && (wantTicks < 0 || s.ticks == wantTicks) && (wantNow < 0 || s.now == wantNow);
            check(name, ok, "expected " + want + " awaits=" + wantAwaits + " ticks=" + wantTicks + " now=" + wantNow
                    + ", got " + got + " awaits=" + s.awaits + " ticks=" + s.ticks + " now=" + s.now);
        } catch (Throwable t) {
            check(name, false, "threw " + t);
        }
    }

    public static void main(String[] args) {
        check("constants", InstallWait.BEAT_MS == 30_000 && InstallWait.LAG_MS == 5_000 && InstallWait.HARD_MS == 600_000,
                "BEAT/LAG/HARD = " + InstallWait.BEAT_MS + "/" + InstallWait.LAG_MS + "/" + InstallWait.HARD_MS);

        run("1 broadcast at 10s", s -> { s.fire = 10_000L; },
                InstallWait.Outcome.BROADCAST, 1, 0, -1);
        run("2 broadcast at 240s, session alive: no failure at 120s", s -> { s.fire = 240_000L; },
                InstallWait.Outcome.BROADCAST, 8, 7, 240_000);
        run("3 gone at 180s, null before, path after -> LANDED", s -> {
            s.sessionEnd = 180_000; s.before = null; s.after = "/data/app/x-1/base.apk"; s.changeAt = 180_000; },
                InstallWait.Outcome.LANDED, 7, 5, 185_000);
        run("4 gone, path unchanged -> GONE_UNCHANGED", s -> {
            s.sessionEnd = 180_000; s.before = "/a"; s.after = "/a"; },
                InstallWait.Outcome.GONE_UNCHANGED, -1, -1, -1);
        run("5 gone at 180s, broadcast at 183s -> BROADCAST (the 5s beat)", s -> {
            s.sessionEnd = 180_000; s.fire = 183_000L; s.before = "/a"; s.after = "/a"; },
                InstallWait.Outcome.BROADCAST, 7, -1, 183_000);
        run("6 /a -> /b -> LANDED", s -> {
            s.sessionEnd = 180_000; s.before = "/a"; s.after = "/b"; s.changeAt = 180_000; },
                InstallWait.Outcome.LANDED, -1, -1, -1);
        run("7 /a -> null -> GONE_UNCHANGED", s -> {
            s.sessionEnd = 180_000; s.before = "/a"; s.after = null; s.changeAt = 180_000; },
                InstallWait.Outcome.GONE_UNCHANGED, -1, -1, -1);
        run("8 session alive forever -> HARD_BOUND", s -> { },
                InstallWait.Outcome.HARD_BOUND, 21, 20, 630_000);

        check("9 message(LANDED)", "session finished without our broadcast; codePath changed"
                .equals(InstallWait.message(InstallWait.Outcome.LANDED)), String.valueOf(InstallWait.message(InstallWait.Outcome.LANDED)));
        check("9 message(GONE_UNCHANGED)", "session gone, codePath unchanged (abandoned or failed without a broadcast)"
                .equals(InstallWait.message(InstallWait.Outcome.GONE_UNCHANGED)), String.valueOf(InstallWait.message(InstallWait.Outcome.GONE_UNCHANGED)));
        check("9 message(HARD_BOUND)", "still installing at the 10-minute hard bound; giving up on WAITING, not on the install"
                .equals(InstallWait.message(InstallWait.Outcome.HARD_BOUND)), String.valueOf(InstallWait.message(InstallWait.Outcome.HARD_BOUND)));
        check("9 message(BROADCAST)", InstallWait.message(InstallWait.Outcome.BROADCAST) == null, "not null");

        System.exit(failed == 0 ? 0 : 1);
    }
}
