package com.nowhere.chooser;

/**
 * When the reap watcher clears a stale {@code sessionLive} (NWP-20261115-12; backlog row "The gate's #73 orphan
 * sweep stays off until a reboot after any secondary user has been unlocked outside a session"). The parked tier's
 * #123 self-heal sets {@code sessionLive} from any unlocked secondary user, and nothing cleared it when that user
 * was removed outside a sign-out. The watcher's fast tier now asks every {@link #RECHECK_MS} whether any secondary
 * user is unlocked; two "none" answers in a row, with no sign-in, reap or switch in flight, clear it. Pure
 * (java.lang only) so a javac suite can pin the rule.
 */
final class SessionLiveClear {
    private SessionLiveClear() {}

    /** The check's cadence: the parked tier's own 15 s. */
    static final long RECHECK_MS = 15000L;

    /**
     * The streak after one check. {@code anyUnlocked} is TRUE when a secondary user is unlocked, FALSE when none
     * is, and null when the watcher is unsure (busy, no UserManager, a throw). Only FALSE on a live, idle session
     * counts; anything else starts the streak again.
     */
    static int observe(int streak, boolean live, boolean busy, Boolean anyUnlocked) {
        if (!live || busy) return 0;
        if (!Boolean.FALSE.equals(anyUnlocked)) return 0; // TRUE (a user is unlocked) or null (unsure)
        return streak + 1;
    }

    /** Two checks in a row saw no unlocked secondary user. */
    static boolean shouldClear(int streak) {
        return streak >= 2;
    }
}
