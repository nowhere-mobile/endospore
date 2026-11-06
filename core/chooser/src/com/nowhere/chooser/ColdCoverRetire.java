package com.nowhere.chooser;

/**
 * When the gate retires the cold-lock cover by itself (NWP-20261120-19; backlog row "THE GATE STAYS ON THE
 * “Locking…” COVER AFTER A HAND-SWITCH TEARDOWN, UNTIL THE SCREEN IS CYCLED"). The #134 cover was retired, and the
 * GET-COLDLOCK reveal run, only from onResume. A hand-switch to user 0 arms the cover while the gate is already in
 * front, so no onResume follows the cold lock and the gate stayed on "Locking…" until the screen was cycled. doColdLock
 * now has the live gate post its own retire at the end of the cover window. Pure (java.lang only) so a javac suite can
 * pin the rule.
 */
final class ColdCoverRetire {
    private ColdCoverRetire() {}

    /** Milliseconds until the retire runs: the rest of the window from coldLockInAt, never negative, plus 250 ms. */
    static long delayMs(long now, long coldLockInAt, long windowMs) {
        return Math.max(0L, coldLockInAt + windowMs - now) + 250L;
    }

    /** The retire acts: this is the live gate, the cover is up, and the cold-lock window is over (or already retired). */
    static boolean due(boolean liveGate, boolean coverShown, boolean coldLockIn, long now, long coldLockInAt, long windowMs) {
        return liveGate && coverShown && (!coldLockIn || now - coldLockInAt >= windowMs);
    }
}
