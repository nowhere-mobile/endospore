package com.nowhere.chooser;

/** NWP-20261121-04: Your data repaints its save lines once GET-SEAL-LANDED moves past the stamp they were painted for.
 *  A periodic save that lands while the screen is open used to leave the old headline and the old "Changed on this
 *  phone" count on screen until the screen was reopened. Pure java.lang, so test-save-lines-refresh-java.sh runs it
 *  under javac. */
final class SaveLinesRefresh {
    /** How often the open screen reads GET-SEAL-LANDED. */
    static final long POLL_MS = 15_000L;
    /** No stamp: an unreadable reply. Equals BackNowCycle.landedStamp's failure value. */
    static final long NOTHING = -1L;

    /** The stamp the save lines were last painted for. */
    private long painted = NOTHING;

    /** GET-SEAL-LANDED's "OK <unix seconds>"; NOTHING for any other reply. The one parser is BackNowCycle's. */
    static long parseLanded(String reply) {
        return BackNowCycle.landedStamp(reply);
    }

    /** loadSealDelta read this stamp before its SEAL-DELTA read. NOTHING changes nothing. */
    synchronized void painted(long stamp) {
        if (stamp == NOTHING) return;
        painted = stamp;
    }

    /** True when the lines must be repainted for this stamp. The first stamp only seeds. A hold (a load in flight,
     *  or the activity paused) leaves the stamp due, so the next tick fires. The load records the stamp itself. */
    synchronized boolean due(long stamp, boolean hold) {
        if (stamp == NOTHING) return false;
        if (painted == NOTHING) {
            painted = stamp;
            return false;
        }
        if (stamp == painted) return false;
        if (hold) return false;
        return true;
    }

    /** The poll keeps going only while its own screen is the one shown, attached, and the activity lives. */
    static boolean keepPolling(boolean sameView, boolean attached, boolean finishing) {
        return sameView && attached && !finishing;
    }
}
