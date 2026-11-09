package com.nowhere.chooser;

/** NWP-20261129-32: whether the Tie screen's progress poll reads, waits or ends on this pass. Each SE-PROGRESS takes
 *  the login daemon's session lock and up to a dozen store reads, so a poll that outlives its screen delays every
 *  materialise, Back up now and sign-out behind it. Pure java.lang, so test-tie-progress-poll-java.sh runs it under
 *  javac. */
final class TieProgressPoll {
    /** How long a pass waits before the next one. */
    static final long POLL_MS = 5000;

    enum Step { READ, WAIT, STOP }

    private TieProgressPoll() {}

    /** STOP for good when the block is off screen, the activity is going or nothing is still moving. WAIT reads nothing
     *  while Profile is not in front; the next pass after onResume reads again. */
    static Step step(boolean attached, boolean finishing, boolean paused, boolean settled) {
        if (!attached || finishing || settled) return Step.STOP;
        if (paused) return Step.WAIT;
        return Step.READ;
    }

    /** True when an SE-PROGRESS reply says nothing is still moving: "OK NONE", or an OK whose rows are all done. A row
     *  is what ProfileActivity.renderTieProgress reads as one. A failed or partial read is false, so the poll goes on. */
    static boolean settled(String reply) {
        if (reply == null || !reply.startsWith("OK")) return false;
        if (reply.startsWith("OK NONE")) return true;
        int rows = 0;
        for (String l : reply.split("\n")) {
            String[] f = l.trim().split(" ");
            if (f.length != 4 || !("MEDIA".equals(f[0]) || "APPS".equals(f[0]))) continue;
            rows++;
            if (!"done".equals(f[1])) return false;
        }
        return rows > 0;
    }
}
