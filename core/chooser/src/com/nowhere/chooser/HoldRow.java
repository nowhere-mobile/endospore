package com.nowhere.chooser;

/** NWP-20261203-23 (backlog "Once the Auto sweep's landing card is closed, the sweep cannot be paused or stopped",
 *  Chester 2026-11-12: both placements): what Your apps' install row offers. RUNNING: a sweep runs and nothing holds
 *  it, so the row offers Pause and Stop. PAUSED: the row offers the Install chip as "Resume installing apps" (a by-hand
 *  start ends the pause). INSTALL: the plain row; a stop is INSTALL, as a by-hand start ends it too. Pure, so
 *  test-sweep-hold-row-java.sh compiles it with its cases. */
final class HoldRow {
    static final int INSTALL = 0, RUNNING = 1, PAUSED = 2;

    private HoldRow() {}

    static int mode(boolean sweepRunning, SweepHold.State s) {
        if (s == SweepHold.State.PAUSED) return PAUSED;
        if (s == SweepHold.State.STOPPED) return INSTALL;
        return sweepRunning ? RUNNING : INSTALL;
    }

    static String label(int mode) {
        if (mode == RUNNING) return LandingLine.RUNNING_ROW;
        if (mode == PAUSED) return LandingLine.RESUME_ROW;
        return "Install pending apps now";
    }
}
