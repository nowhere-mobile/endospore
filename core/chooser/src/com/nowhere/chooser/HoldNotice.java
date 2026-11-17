package com.nowhere.chooser;

/** NWP-20261203-18 (backlog "Once the Auto sweep's landing card is closed, the sweep cannot be paused or stopped: Pause
 *  and Stop live only on the card"): placement A, the progress notification's Pause and Stop. Chester chose both
 *  placements (2026-11-12); the sibling task builds placement B, Your apps' row. UnarchiveService adds the two actions
 *  while offer() is true, and its EXTRA_HOLD arm checks offer() again before it holds the sweep, so a stale action does
 *  nothing. java.lang only, so test-sweep-hold-notice-java.sh compiles it with its cases alone. */
final class HoldNotice {
    /** The EXTRA_HOLD words, which the arm also logs. */
    static final String HOLD_PAUSE = "pause", HOLD_STOP = "stop";

    private HoldNotice() {}

    /** The notification offers Pause and Stop only while a sweep runs and nothing holds it. */
    static boolean offer(boolean sweepRunning, SweepHold.State s) {
        return sweepRunning && s == SweepHold.State.NONE;
    }
}
