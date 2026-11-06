package com.nowhere.chooser;

/** NWP-20261118-05: what the Auto sweep does when MATERIALIZE-APP answers ERR-WORKER-BUSY. Field-seen on frankel
 *  0.5.49 (ticket NW-0ee95acd7ad4): a three-minute odrestore held the daemon's RW worker lane, every one of the
 *  sweep's 45 MATERIALIZE-APP calls answered busy in 2-3 s, and all 45 apps ended `fetch-failed` with no retry
 *  until the next sign-in. ERR-WORKER-BUSY means nothing was attempted (NWP-20261022-02): an op the daemon gave up
 *  waiting on still holds the lane. So a busy app is not a failed download. sweepAuto retries the SAME app on the
 *  growing schedule waitMs(), and when the next wait would pass BOUND_MS it reports the app `busy` and leaves it,
 *  and every app after it, for the next sweep (their placeholders stay).
 *
 *  BOUND_MS sits below the daemon's autoSweepLease (10 min, core/agent/auto_sweep.go). Each MATERIALIZE-APP,
 *  busy or not, renews that lease, and the longest gap between two calls is one wait plus one call, so the
 *  sweep's seal hold never lapses while it waits. sweepAuto decides only through step(). java.* only, so
 *  test-sweep-busy-java.sh compiles it with SweepOutcome alone. */
final class SweepBusy {
    /** The daemon's reply when the worker lane stayed busy (core/agent/main.go workerBusy). */
    static final String BUSY_REPLY = "ERR-WORKER-BUSY";
    /** The most one app waits out a busy lane in total: 5 min, below the daemon's 10 min autoSweepLease. */
    static final long BOUND_MS = 300_000L;
    /** The wait before each retry, by attempt; every later attempt waits the last value. */
    private static final long[] SCHEDULE_MS = { 5_000L, 10_000L, 20_000L, 40_000L, 60_000L };

    enum Step { NEXT, RETRY, STOP }

    private SweepBusy() {}

    /** True only when the reply's first whitespace-separated token, trimmed, is exactly ERR-WORKER-BUSY. */
    static boolean isBusy(String reply) {
        if (reply == null) return false;
        String r = reply.trim();
        if (r.isEmpty()) return false;
        int sp = 0;
        while (sp < r.length() && !Character.isWhitespace(r.charAt(sp))) sp++;
        return BUSY_REPLY.equals(r.substring(0, sp));
    }

    /** The wait before retry number attempt + 1: 5, 10, 20, 40 s, then 60 s for every later attempt. */
    static long waitMs(int attempt) {
        if (attempt < 0) attempt = 0;
        return SCHEDULE_MS[Math.min(attempt, SCHEDULE_MS.length - 1)];
    }

    /** NEXT when the app did not end busy; RETRY when it did and waiting waitMs(attempt) more keeps the app's total
     *  wait within BOUND_MS; STOP otherwise. attempt is the retries already made for this app, waitedMs their sum. */
    static Step step(String end, int attempt, long waitedMs) {
        if (!SweepOutcome.BUSY.equals(end)) return Step.NEXT;
        if (waitedMs + waitMs(attempt) <= BOUND_MS) return Step.RETRY;
        return Step.STOP;
    }
}
