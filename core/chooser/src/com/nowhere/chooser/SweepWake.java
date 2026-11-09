package com.nowhere.chooser;

/** NWP-20261128-07: the Auto sweep keeps the processor awake until it ends, for at most 2 hours (decided 2026-11-04,
 *  docs/product-decisions.md). Measured on frankel (NWP-20261104-37): once the screen went off, 82% of a long sweep's
 *  window was spent suspended, and apps 30 onward took 9 to 39 minutes each. The only lock near the sweep was the
 *  tap's `nowhere:appfetch`, which lapses after 25 minutes; the sweep itself held nothing.
 *
 *  UnarchiveService.sweepAutoJoined builds one PARTIAL lock per sweep (`nowhere:autosweep`), calls begin() right after
 *  it owns the walk (SweepJoin.enter) and end() in a finally after its last pass. PARTIAL keeps the processor awake and
 *  never the screen. CAP_MS is the decided cap: the timeout of WakeLock.acquire(long) counts on the elapsed-realtime
 *  clock, so it counts real time from the sweep's start, suspend included. At the cap the lock lapses and the sweep
 *  carries on unheld; nothing is cancelled. end() releases only a held lock: a lock its timeout released throws
 *  "under-locked" on release() (the same guard as fetchWakeRelease). Neither method throws.
 *
 *  Each sweep's start time is kept per Lock (`running`, under MON), because two sweeps can overlap:
 *  SweepJoin.exit() ends the join inside the loop's finally, and end() runs after it, in the outer finally. A start in
 *  that gap owns a new walk and calls begin() before the old owner's end(). Each sweep releases only its own lock and
 *  logs its own held time. java.lang only, so test-sweep-wake-java.sh compiles it with its cases alone. */
final class SweepWake {
    /** The decided 2 hours, in ms (7200000). */
    static final long CAP_MS = 2L * 60 * 60 * 1000;

    /** One sweep's lock. The adapter in UnarchiveService wraps a PowerManager.WakeLock. */
    interface Lock {
        void acquire(long ms);
        void release();
        boolean isHeld();
        /** The clock for the held time. The adapter returns SystemClock.elapsedRealtime(), which counts suspend. */
        default long now() { return 0L; }
        /** One logcat line. The adapter writes it under "NowhereChooser", with the throw when there is one. */
        default void log(String line, Throwable t) {}
    }

    /** One running sweep: its Lock and its now() at begin(). */
    private static final class Since {
        final Lock lock; final long t0; Since next;
        Since(Lock lock, long t0, Since next) { this.lock = lock; this.t0 = t0; this.next = next; }
    }
    private static final Object MON = new Object();
    private static final long NONE = Long.MIN_VALUE;
    private static Since running; // every sweep between its begin() and its end(); at most two in practice

    /** Drops l's entry (matched by identity) and returns its t0, or NONE when it has none. Call under MON. */
    private static long take(Lock l) {
        for (Since p = null, s = running; s != null; p = s, s = s.next) {
            if (s.lock != l) continue;
            if (p == null) running = s.next; else p.next = s.next;
            return s.t0;
        }
        return NONE;
    }

    private SweepWake() {}

    /** At the sweep's start: acquire for at most CAP_MS. A throw is logged, never thrown: the sweep runs unheld. */
    static void begin(Lock l) {
        try {
            long t0 = l.now();
            synchronized (MON) { take(l); running = new Since(l, t0, running); }
            l.acquire(CAP_MS);
            say(l, "#130 sweep wake lock: held, at most " + CAP_MS + " ms (NWP-20261128-07)", null);
        } catch (Throwable t) {
            say(l, "#130 sweep wake lock: the acquire failed, the sweep runs unheld (NWP-20261128-07)", t);
        }
    }

    /** After the sweep's last pass: release when still held. A throw is logged, never thrown. */
    static void end(Lock l) {
        try {
            long t1 = l.now();
            long held = -1;
            synchronized (MON) {
                long t0 = take(l);
                if (t0 != NONE) held = t1 - t0;
            }
            if (l.isHeld()) {
                l.release();
                say(l, "#130 sweep wake lock: released " + (held >= 0 ? "after " + held + " ms"
                        : "(its held time is not known: begin did not run)") + " (NWP-20261128-07)", null);
            } else {
                say(l, "#130 sweep wake lock: not held at the end (the 2-hour cap lapsed it, or the acquire failed)"
                        + (held >= 0 ? "; the sweep ran " + held + " ms" : "") + " (NWP-20261128-07)", null);
            }
        } catch (Throwable t) {
            say(l, "#130 sweep wake lock: the release failed (NWP-20261128-07)", t);
        }
    }

    private static void say(Lock l, String line, Throwable t) {
        try { l.log(line, t); } catch (Throwable ignored) {}
    }
}
