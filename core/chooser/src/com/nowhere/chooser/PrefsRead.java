package com.nowhere.chooser;

import java.util.List;
import java.util.function.IntFunction;
import java.util.function.LongConsumer;
import java.util.function.LongSupplier;

/** NWP-20261118-11: the sign-in's GET-PREFS read, retried when it fails, bounded. On frankel 0.5.49 the read timed out
 *  behind the grant op, came back as an empty list (the same as "no saved prefs"), and the session ran on the
 *  defaults: the idle cold lock armed at 15 minutes on a profile set to Never. The reader answers null for a failed
 *  read and a list (empty included) for a reply, so the two are told apart here. The timing is DozeApplyRetry's: the
 *  first read is capped at FIRST_READ_MS, as before; a failed read is repeated BACKOFF_MS apart until BUDGET_MS has
 *  passed since the FIRST read ended, each later read capped at the budget left, at least MIN_READ_MS.
 *  Pure: java.lang, java.util and java.util.function only, so test-prefs-read-java.sh compiles it as is. */
final class PrefsRead {
    /** Retry for this long after the first read ends. */
    static final long BUDGET_MS = 10_000;
    /** The wait between two reads; the last wait is cut to what is left of the budget. */
    static final long BACKOFF_MS = 1_000;
    /** The first read's cap, as before the retry existed. */
    static final int FIRST_READ_MS = 30_000;
    /** A later read waits only for the budget left, but never less than this. */
    static final int MIN_READ_MS = 1_000;

    private PrefsRead() {}

    /** reader.apply(capMs) reads once with that read cap and returns the reply lines, or null for a failed read.
     *  Returns the first non-null reply (an empty list is a reply: no saved prefs), or null when every read failed
     *  and the budget is spent. */
    static List<String> read(IntFunction<List<String>> reader, LongSupplier nowMs, LongConsumer sleepMs) {
        List<String> lines = reader.apply(FIRST_READ_MS);
        final long start = nowMs.getAsLong();
        int tries = 1;
        while (lines == null) {
            long left = BUDGET_MS - (nowMs.getAsLong() - start);
            if (left <= 0) break;
            sleepMs.accept(Math.min(BACKOFF_MS, left));
            lines = reader.apply(capMs(tries++, start, nowMs.getAsLong()));
        }
        return lines;
    }

    /** The read cap for a read after priorTries earlier ones: FIRST_READ_MS for the first, then the budget left since
     *  the first read ended (firstEndedMs), at least MIN_READ_MS. */
    static int capMs(int priorTries, long firstEndedMs, long nowMs) {
        if (priorTries == 0) return FIRST_READ_MS;
        return (int) Math.max(MIN_READ_MS, BUDGET_MS - (nowMs - firstEndedMs));
    }
}
