package com.nowhere.chooser;

/** NWP-20261027-12: what the Your apps screen does to its "Install pending apps now" row when the count of pending
 *  Auto apps changes. The row was counted once per build, so an app set to Auto never brought it up (lynx 0.5.48,
 *  2026-10-19). Pure Java, no android.* import, so core/chooser/test-pending-row-java.sh compiles it as it stands. */
final class PendingRow {
    static final int NONE = 0, ADD = 1, REPLACE = 2, REMOVE = 3;

    private PendingRow() {}

    /** shown: the count the visible row says (0 = no row); n: the fresh count. Negative inputs read as 0. */
    static int action(int shown, int n) {
        return action(shown, n, false);
    }

    /** As action(shown, n), and sweepEnded: the count comes from a sweep's end. A row that still says the same count is
     *  rebuilt (REPLACE), so its chip, which a tap set to "Started" with no listener, says "Install" again
     *  (NWP-20261119-30). */
    static int action(int shown, int n, boolean sweepEnded) {
        if (shown < 0) shown = 0;
        if (n < 0) n = 0;
        if (n > 0 && shown == 0) return ADD;
        if (n > 0 && shown != n) return REPLACE;
        if (sweepEnded && n > 0) return REPLACE;   // shown == n here: a sweep ended and left apps pending
        if (n == 0 && shown > 0) return REMOVE;
        return NONE;
    }
}
