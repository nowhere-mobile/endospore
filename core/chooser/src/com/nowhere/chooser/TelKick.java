package com.nowhere.chooser;

/**
 * NWP-20261019-04: repeats a telephony delivery kick. A failed logoff's daemon stages the session's RAM-only inbox
 * AFTER SEAL-STATUS already says FAILED, so a single kick can claim an empty mailbox; the Profile screen re-kicks on a
 * timer instead. Pure java.lang so it is compiled and run off-device (core/chooser/tests/tel-kick).
 */
final class TelKick {
    private TelKick() {}

    interface Sleeper {
        void sleep(long ms) throws InterruptedException;
    }

    /**
     * Runs {@code kick} {@code times} times with {@code gapMs} between consecutive runs and returns how many it
     * attempted. A kick that throws is skipped silently and the loop goes on; neither a failed nor a successful start
     * ends it early. Only an interrupted sleeper stops it.
     */
    static int repeat(Runnable kick, int times, long gapMs, Sleeper sleeper) {
        int attempted = 0;
        for (int i = 0; i < times; i++) {
            if (i > 0) {
                try {
                    sleeper.sleep(gapMs);
                } catch (InterruptedException ie) {
                    return attempted;
                }
            }
            attempted++;
            try {
                kick.run();
            } catch (Throwable ignored) {
                // the next run may succeed
            }
        }
        return attempted;
    }
}
