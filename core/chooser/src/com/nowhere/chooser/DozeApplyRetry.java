package com.nowhere.chooser;

import java.util.function.BooleanSupplier;
import java.util.function.LongConsumer;
import java.util.function.LongSupplier;

/** NWP-20261116-14 (dn-1023 #3, docs/product-decisions.md 2026-10-24): the login apply of a profile's own Doze
 *  choices retries until it holds, bounded, before the switch-in. One attempt is the daemon read of the own set,
 *  then the reset of foreign entries; the caller supplies it and answers whether it held. A failed attempt is repeated
 *  BACKOFF_MS apart until BUDGET_MS (about 10 s) has passed since the FIRST attempt ended, so a slow first read
 *  still gets its retries, and an attempt that ends past the budget is the last one. A failed outcome leaves the
 *  live record disarmed (the caller arms it only on true). NWP-20261117-06: the gate then tells the login daemon
 *  whether the session is armed (DOZE-ARM), and the session's capture asks before it writes (GET-DOZE-ARM,
 *  mayCapture), so an unarmed session's sign-out leaves the restored record untouched.
 *  Pure: java.lang and java.util.function only, so test-doze-apply-retry-java.sh compiles it as is. */
final class DozeApplyRetry {
    /** Retry for this long after the first attempt ends. */
    static final long BUDGET_MS = 10_000;
    /** The wait between two attempts; the last wait is cut to what is left of the budget. */
    static final long BACKOFF_MS = 1_000;
    /** The first read's cap, as before the retry existed. */
    static final int FIRST_READ_MS = 30_000;
    /** A later read waits only for the budget left, but never less than this. */
    static final int MIN_READ_MS = 1_000;

    private DozeApplyRetry() {}

    /** Runs attempt; while it answers false and less than BUDGET_MS has passed since the first attempt ended,
     *  sleeps min(BACKOFF_MS, what is left) and runs it again. Returns whether the last attempt held. */
    static boolean run(BooleanSupplier attempt, LongSupplier nowMs, LongConsumer sleepMs) {
        boolean held = attempt.getAsBoolean();
        final long start = nowMs.getAsLong();
        while (!held) {
            long left = BUDGET_MS - (nowMs.getAsLong() - start);
            if (left <= 0) break;
            sleepMs.accept(Math.min(BACKOFF_MS, left));
            held = attempt.getAsBoolean();
        }
        return held;
    }

    /** The read timeout for an attempt after priorTries earlier ones: FIRST_READ_MS for the first, then the budget
     *  left since the first attempt ended (firstEndedMs), at least MIN_READ_MS. */
    static int readTimeoutMs(int priorTries, long firstEndedMs, long nowMs) {
        if (priorTries == 0) return FIRST_READ_MS;
        return (int) Math.max(MIN_READ_MS, BUDGET_MS - (nowMs - firstEndedMs));
    }

    /** NWP-20261117-06: whether the session's capture may write its record, from the daemon's GET-DOZE-ARM reply. Only
     *  exactly "UNARMED" stops it; any other reply, no reply (null or "") included, captures as before this slice. */
    static boolean mayCapture(String reply) {
        return !"UNARMED".equals(reply);
    }
}
