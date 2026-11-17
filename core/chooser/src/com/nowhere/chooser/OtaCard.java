package com.nowhere.chooser;

/**
 * NWP-20261206-19: what the Software update screen's Install update button shows around a tap.
 *
 * A tap used to drop OTA-APPLY's answer and render the next OTA-STATUS at once. In the first seconds of an apply that
 * read can be a cached "AVAIL <ver>", an empty reply, or "FAILED ERR-STALE" (the daemon's dead-worker check before
 * init marks otad running), and each one re-offered Install update while otad was applying (backlog: "The Update card
 * shows Install update again while an update is installing, and lets it be tapped again"). After OTA-APPLY answers OK
 * or BUSY the screen keeps "Starting update…" over those three replies for HOLD_MS; any other reply ends the hold at
 * once, so a real failure is shown as before.
 *
 * Pure Java, no Android types, so core/chooser/tests/ota-card runs it under a plain JDK
 * (core/vendor-common/bin/test-ota-card-java.sh).
 */
final class OtaCard {
    private OtaCard() {}

    /** How long after an accepted OTA-APPLY the screen holds "Starting update…" over a reply that would re-offer Install. */
    static final long HOLD_MS = 60000;

    /** Install update is offered for something installable (AVAIL) or to retry a failed install (FAILED). */
    static boolean installShown(String head) {
        return "AVAIL".equals(head) || "FAILED".equals(head);
    }

    /** OTA-APPLY started an install (OK) or one is already running (BUSY). Anything else started nothing. */
    static boolean applyStarted(String reply) {
        if (reply == null) return false;
        String r = reply.trim();
        return "OK".equals(r) || "BUSY".equals(r);
    }

    /** Keep "Starting update…" instead of rendering OTA-STATUS line 1 ({@code statusLine}), msSinceApply after the tap. */
    static boolean holdStarting(String applyReply, String statusLine, long msSinceApply) {
        if (!applyStarted(applyReply)) return false;
        if (msSinceApply < 0 || msSinceApply >= HOLD_MS) return false;
        String s = statusLine == null ? "" : statusLine.trim();
        if (s.isEmpty()) return true;
        if ("AVAIL".equals(s.split(" ", 2)[0])) return true;
        return "FAILED ERR-STALE".equals(s);
    }
}
