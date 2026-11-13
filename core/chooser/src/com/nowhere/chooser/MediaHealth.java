package com.nowhere.chooser;

import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicReference;

/**
 * NWP-20261202-26: the media-health rule. Backlog row "The phone does not notice when the session's media service stops
 * answering, although restarting it brings back the alarm list, the Gallery and shared storage at once" (§B). Decision
 * of record: docs/product-decisions.md, 2026-11-08 (a fixed rule: a condition, a fix and a message; it runs during a
 * session, nothing leaves the phone, it never repairs on its own and never signs out).
 *
 * The fault: every binder thread of the session's MediaProvider waits on one monitor, so ANY call into it, even one it
 * would refuse, never returns. So an exception IS an answer: only a call that does not return inside the limit counts
 * as hung. The condition: the session user's one-row MediaStore query times out on FIRE_AFTER consecutive runs while
 * the same query for user 0 answers. A run where user 0 times out too is a busy phone and resets the count.
 *
 * Pure: no Android API and no daemon socket, so javac compiles it with no stubs (test-media-health-java.sh). probe keeps
 * at most one stuck thread per AtomicReference: while the previous probe thread is still alive it returns TIMED_OUT and
 * starts nothing, and concurrent callers on one reference check, reserve and start under that reference's lock.
 */
final class MediaHealth {
    private MediaHealth() {}

    static final long PROBE_LIMIT_MS = 5000;
    static final long CHECK_EVERY_MS = 5 * 60 * 1000L;
    static final int FIRE_AFTER = 2;

    // Probe outcomes.
    static final int ANSWERED = 0, TIMED_OUT = 1, ERROR = 2;
    // What the watcher does with the notice.
    static final int KEEP = 0, FIRE = 1, CANCEL = 2;

    static final String TITLE = "Photos and alarms can't load right now"; // DRAFT, Chester approves (NWP-20261202-26)
    static final String BODY = "The phone's media service stopped answering. Tap Fix to restart it; if a save is running, the restart waits for it to finish."; // DRAFT, Chester approves (NWP-20261202-26)
    static final String FIX = "Fix"; // DRAFT, Chester approves (NWP-20261202-26)
    // The body of the notice re-posted without Fix after the daemon refused the restart.
    static final String BODY_NO_FIX = "The phone's media service stopped answering. The phone could not restart it."; // DRAFT, Chester approves (NWP-20261202-26)

    /** The miss count after one run. Only a session timeout while user 0 did not time out counts. */
    static int nextMisses(int misses, int session, int owner) {
        if (session != TIMED_OUT) return 0; // answered or error: the service answers
        if (owner == TIMED_OUT) return 0;   // busy phone: user 0 is slow too, reset
        return misses + 1;
    }

    /** What to do with the notice, from the miss count AFTER nextMisses and this run's session outcome. */
    static int offer(int misses, int session) {
        if (session != TIMED_OUT) return CANCEL;
        if (misses >= FIRE_AFTER) return FIRE;
        return KEEP;
    }

    /** Run {@code call} on a daemon thread and wait at most {@code limitMs}. ANSWERED when it returns, ERROR when it
     *  throws, TIMED_OUT when it is still running. A thread still running stays in {@code outstanding}, and while it
     *  is alive every later probe on that reference returns TIMED_OUT without calling {@code call}. */
    static int probe(final Callable<?> call, long limitMs, AtomicReference<Thread> outstanding) {
        final int[] out = {TIMED_OUT};
        Thread t = new Thread(() -> {
            int r;
            try {
                call.call();
                r = ANSWERED;
            } catch (Throwable e) {
                r = ERROR;
            }
            synchronized (out) { out[0] = r; }
        }, "nowhere-media-probe");
        t.setDaemon(true);
        // The check, the reservation and the start are one step per reference: two callers at once (a manual and a
        // scheduled issue report share one reference) must not both start a query. The join stays outside the lock.
        synchronized (outstanding) {
            Thread prev = outstanding.get();
            if (prev != null && prev.isAlive()) return TIMED_OUT;
            outstanding.set(t);
            t.start();
        }
        try {
            t.join(limitMs);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            return TIMED_OUT;
        }
        if (t.isAlive()) return TIMED_OUT;
        outstanding.compareAndSet(t, null);
        synchronized (out) { return out[0]; }
    }

    /** MEDIA-RESTART's reply: only QUEUED is accepted. DENIED, ERR-NOSESSION, a daemon's unknown-verb refusal, an
     *  empty reply (no daemon) and null are refusals. */
    static boolean fixAccepted(String reply) {
        if (reply == null) return false;
        String t = reply.trim();
        if (t.isEmpty()) return false;
        return t.split("\\s+", 2)[0].equals("QUEUED");
    }

    /** The issue report's media_probe value. */
    static String reportValue(int outcome, long ms) {
        if (outcome == ANSWERED) return "answered ms=" + ms;
        if (outcome == TIMED_OUT) return "timeout ms=" + PROBE_LIMIT_MS;
        return "error";
    }

    static String outcomeName(int outcome) {
        if (outcome == ANSWERED) return "answered";
        if (outcome == TIMED_OUT) return "timeout";
        return "error";
    }

    /** The one log line per verdict change. Ints only: no profile or app name can enter it. */
    static String logLine(boolean firing, int session, int owner, int misses) {
        return "media health: " + (firing ? "FIRING" : "CLEAR") + " (session=" + outcomeName(session)
                + " owner=" + outcomeName(owner) + " misses=" + misses + ")";
    }
}
