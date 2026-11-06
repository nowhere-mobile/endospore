package com.nowhere.chooser;

/**
 * NWP-20261124-04: when the session's "Locking…" cover ({@link ColdLockCoverActivity}) may end. Chester, 2026-11-02:
 * "go with option 1 for 1475" -- after the idle cold lock commits, the owner sees no session screen until the daemon's
 * own switch to the gate. So only that switch ends the cover. Home, Recents or a tapped notification stop the cover
 * with the session still in front; the cover then raises itself again. A stop with the screen off keeps the cover where
 * it is: it is still the top of its task, so it is the first thing the next unlock shows.
 * Pure (java.* only), so test-coldlock-abort-reply-java.sh compiles it alone.
 */
final class ColdLockCoverRule {
    enum Step {
        /** The switch to the gate landed: the session is no longer in front. Finish the cover. */
        END,
        /** The session is still in front and the screen is on: something covered the cover. Raise it again. */
        RAISE,
        /** The session is still in front and the screen is off: keep the cover, start nothing. */
        KEEP
    }

    private ColdLockCoverRule() {}

    /**
     * @param currentUser the foreground user, or a negative value when the read failed
     * @param coverUser the user the cover runs in (the session)
     * @param interactive whether the screen is on
     */
    static Step afterStop(int currentUser, int coverUser, boolean interactive) {
        // An unknown foreground user fails closed: the cover stays. Raising it in a user that has already gone to the
        // background shows nothing, and the switch's user stop removes it.
        if (currentUser >= 0 && currentUser != coverUser) return Step.END;
        return interactive ? Step.RAISE : Step.KEEP;
    }
}
