package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** NWP-20261128-07: SweepWake, compiled with that file ALONE and executed by
 *  core/vendor-common/bin/test-sweep-wake-java.sh. The fake lock stands in for a PowerManager.WakeLock: its release()
 *  throws "under-locked" when it is not held, as a lock its timeout released does. */
public final class SweepWakeCases {
    static int bad = 0;
    static void check(String id, boolean cond, String what) {
        if (cond) return;
        System.out.println("FAIL " + id + " " + what);
        failed.add(id);
        bad++;
    }
    static final Set<String> failed = new LinkedHashSet<>();
    static void ok(String id, String what) { if (!failed.contains(id)) System.out.println("ok " + id + " " + what); }

    /** A shared fake clock, so two fakes can read one timeline. */
    static long clock = 0L;

    static final class Fake implements SweepWake.Lock {
        int acquires, releases;
        long lastMs = -1;
        boolean held;
        boolean throwAcquire, throwIsHeld, throwRelease;
        final List<String> lines = new ArrayList<>();
        @Override public void acquire(long ms) {
            acquires++;
            lastMs = ms;
            if (throwAcquire) throw new RuntimeException("acquire failed");
            held = true;
        }
        @Override public void release() {
            if (throwRelease) throw new RuntimeException("release failed");
            if (!held) throw new RuntimeException("WakeLock under-locked nowhere:autosweep");
            releases++;
            held = false;
        }
        @Override public boolean isHeld() {
            if (throwIsHeld) throw new RuntimeException("isHeld failed");
            return held;
        }
        @Override public long now() { return clock; }
        @Override public void log(String line, Throwable t) { lines.add(line); }
        String last() { return lines.isEmpty() ? "" : lines.get(lines.size() - 1); }
    }

    /** One sweep body; it may throw. */
    interface Body { void run() throws Exception; }

    /** UnarchiveService.sweepAutoJoined's shape around its loop: begin, then the loop in a try, end in the finally. */
    static void run(SweepWake.Lock l, Body body) throws Exception {
        SweepWake.begin(l);
        try { body.run(); }
        finally { SweepWake.end(l); }
    }

    static boolean noThrow(Runnable r) {
        try { r.run(); return true; } catch (Throwable t) { return false; }
    }

    public static void main(String[] args) {
        // W1 begin calls acquire exactly once with exactly 7200000.
        {
            Fake f = new Fake();
            SweepWake.begin(f);
            check("W1", SweepWake.CAP_MS == 7200000L, "CAP_MS is " + SweepWake.CAP_MS + ", not 7200000");
            check("W1", f.acquires == 1, "acquire ran " + f.acquires + " times, not once");
            check("W1", f.lastMs == 7200000L, "acquire got " + f.lastMs + " ms, not 7200000");
            SweepWake.end(f);
            ok("W1", "begin acquires once, for exactly 7200000 ms (the decided 2 hours)");
        }
        // W2 end on a held lock releases it once.
        {
            Fake f = new Fake();
            SweepWake.begin(f);
            boolean nt = noThrow(() -> SweepWake.end(f));
            check("W2", nt, "end threw on a held lock");
            check("W2", f.releases == 1, "release ran " + f.releases + " times, not once");
            check("W2", !f.held, "the lock is still held after end");
            ok("W2", "end releases a held lock once");
        }
        // W3 end on a lock its timeout lapsed: no release (the fake would throw "under-locked"), and no throw.
        {
            Fake f = new Fake();
            SweepWake.begin(f);
            f.held = false; // the 2-hour cap lapsed it
            boolean nt = noThrow(() -> SweepWake.end(f));
            check("W3", nt, "end threw on a lapsed lock");
            check("W3", f.releases == 0, "release ran on a lock that was not held");
            check("W3", f.last().contains("not held at the end"), "the end line does not say the lock was not held: " + f.last());
            ok("W3", "end does not release a lock that is no longer held, and does not throw");
        }
        // W4 a throwing acquire does not throw out of begin.
        {
            Fake f = new Fake();
            f.throwAcquire = true;
            boolean nt = noThrow(() -> SweepWake.begin(f));
            check("W4", nt, "begin threw when acquire threw");
            boolean nt2 = noThrow(() -> SweepWake.end(f));
            check("W4", nt2, "end threw after a failed acquire");
            check("W4", f.releases == 0, "end released a lock that was never acquired");
            ok("W4", "a throwing acquire does not throw out of begin");
        }
        // W5 a throwing release, or a throwing isHeld, does not throw out of end.
        {
            Fake f = new Fake();
            SweepWake.begin(f);
            f.throwRelease = true;
            check("W5", noThrow(() -> SweepWake.end(f)), "end threw when release threw");
            Fake g = new Fake();
            SweepWake.begin(g);
            g.throwIsHeld = true;
            check("W5", noThrow(() -> SweepWake.end(g)), "end threw when isHeld threw");
            ok("W5", "a throwing release or isHeld does not throw out of end");
        }
        // W6 begin/try/finally/end releases after a body that returns and after one that throws.
        {
            Fake f = new Fake();
            boolean nt = true;
            try { run(f, () -> {}); } catch (Throwable t) { nt = false; }
            check("W6", nt, "a body that returns threw out of run");
            check("W6", f.releases == 1 && !f.held, "the lock was not released after a body that returns");
            Fake g = new Fake();
            Throwable seen = null;
            try { run(g, () -> { throw new IllegalStateException("pass"); }); } catch (Throwable t) { seen = t; }
            check("W6", seen instanceof IllegalStateException, "the body's throw did not reach the caller");
            check("W6", g.acquires == 1 && g.releases == 1 && !g.held, "the lock was not released after a body that throws");
            ok("W6", "the lock is released after a body that returns and after one that throws");
        }
        // W7 begin and end each log exactly one line on the normal path.
        {
            Fake f = new Fake();
            SweepWake.begin(f);
            check("W7", f.lines.size() == 1, "begin logged " + f.lines.size() + " lines, not one");
            SweepWake.end(f);
            check("W7", f.lines.size() == 2, "begin and end logged " + f.lines.size() + " lines, not two");
            for (String s : f.lines) check("W7", s.contains("#130 sweep wake lock:"), "a line lacks the prefix: " + s);
            ok("W7", "begin and end each log one line");
        }
        // W8 two sweeps overlap in the SweepJoin gap: begin(A), begin(B), end(A), end(B). Each releases only its own
        // lock and logs its own held time: B's begin does not overwrite A's start.
        {
            Fake a = new Fake(), b = new Fake();
            clock = 100; SweepWake.begin(a);
            clock = 500; SweepWake.begin(b);
            clock = 900; SweepWake.end(a);
            check("W8", a.releases == 1 && !a.held, "A's lock was not released once by end(A)");
            check("W8", b.held && b.releases == 0, "end(A) touched B's lock");
            check("W8", a.last().contains("after 800 ms"), "end(A) did not log its own 800 ms: " + a.last());
            clock = 1000; SweepWake.end(b);
            check("W8", b.releases == 1 && !b.held, "B's lock was not released once by end(B)");
            check("W8", b.last().contains("after 500 ms"), "end(B) did not log its own 500 ms: " + b.last());
            // The same overlap, ended in the other order: end(B) first, then end(A).
            Fake c = new Fake(), d = new Fake();
            clock = 2000; SweepWake.begin(c);
            clock = 2300; SweepWake.begin(d);
            clock = 2400; SweepWake.end(d);
            clock = 2700; SweepWake.end(c);
            check("W8", d.last().contains("after 100 ms"), "end(D) did not log its own 100 ms: " + d.last());
            check("W8", c.last().contains("after 700 ms"), "end(C) did not log its own 700 ms: " + c.last());
            // A lone sweep, after the others ended: nothing of theirs is left behind.
            Fake e = new Fake();
            clock = 100; SweepWake.begin(e);
            clock = 350; SweepWake.end(e);
            check("W8", e.last().contains("after 250 ms"), "a lone sweep did not log its 250 ms: " + e.last());
            ok("W8", "overlapping sweeps each release their own lock and log their own held time");
        }
        if (bad > 0) { System.out.println("SweepWakeCases: " + bad + " check(s) failed"); System.exit(1); }
        System.out.println("SweepWakeCases: all cases pass");
    }
}
