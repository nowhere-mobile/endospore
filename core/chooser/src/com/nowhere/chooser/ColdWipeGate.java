package com.nowhere.chooser;

/**
 * The cold-lock hard wipe's go/no-go (NWP-20261023-06), lifted out of ChooserActivity.coldWipe so javac can run it.
 * The wipe removes a cold-locked session's user without a sign-out, so it stands down unless the lock-free
 * GET-COLDLOCK reply names this uid AND CLAIM-COLDLOCK answered exactly "OK" (NWP-20261004-01). NWP-20261106-13: no
 * answer at all is neither of those; it is asked again later (unanswered, retryDelayMs). NWP-20261123-20: a try that
 * reads NONE after an unanswered one removes the alarm's user only through removeOnNone (onNone). Pure: java.lang only.
 */
final class ColdWipeGate {
    private ColdWipeGate() {}

    /** The uid field of a "COLDLOCK <uid> <name>" reply; null when the reply is not a cold-lock marker. */
    static String markerUid(String getColdLockReply) {
        if (getColdLockReply == null || !getColdLockReply.startsWith("COLDLOCK ")) return null;
        String rest = getColdLockReply.substring(9).trim(); // "<uid> <name>"
        int sp = rest.indexOf(' ');
        return sp > 0 ? rest.substring(0, sp) : rest;
    }

    /** True when the marker in the reply is this uid's. */
    static boolean markerNames(String getColdLockReply, int uid) {
        return Integer.toString(uid).equals(markerUid(getColdLockReply));
    }

    /** True only for a CLAIM-COLDLOCK answer of exactly "OK"; GONE, no answer or anything else is not a yes. */
    static boolean claimed(String claimReply) {
        return "OK".equals(claimReply);
    }

    /**
     * NWP-20261123-20: a coldWipe try read NONE. Remove the alarm's user only when a lost CLAIM-COLDLOCK OK is the one
     * explanation left: the previous try of this alarm went unanswered, the user still exists, is locked, is not the
     * current user, and no sign-in, resume or sign-out runs. NONE with the user resumed and live is the owner's session.
     */
    static boolean removeOnNone(boolean afterUnansweredTry, boolean userExists, boolean unlocked, boolean current,
                                boolean flowRunning) {
        return afterUnansweredTry && userExists && !unlocked && !current && !flowRunning;
    }

    /** The removal step a NONE try runs: reapOrphanSecondaryUsers' step for one uid (NWP-20261123-20). */
    interface NoneRemoval {
        /** Removes the user; true only when the removal was accepted. */
        boolean removeUser(int uid);
        /** Cleans the removed user's storage (CLEAN-STORAGE). */
        void cleanStorage(int uid);
    }

    /** onNone's results. */
    static final int NONE_KEPT = 0, NONE_REMOVED = 1, NONE_REFUSED = 2;

    /**
     * NWP-20261123-20: the gate instance's NONE consumer. It removes the user only when removeOnNone says yes, and
     * cleans its storage only when the removal was accepted; a refused or throwing removal leaves the storage alone.
     */
    static int onNone(int uid, boolean afterUnansweredTry, boolean userExists, boolean unlocked, boolean current,
                      boolean flowRunning, NoneRemoval r) {
        if (!removeOnNone(afterUnansweredTry, userExists, unlocked, current, flowRunning)) return NONE_KEPT;
        boolean removed;
        try { removed = r.removeUser(uid); } catch (RuntimeException e) { removed = false; }
        if (!removed) return NONE_REFUSED;
        r.cleanStorage(uid);
        return NONE_REMOVED;
    }

    /** Tries at the fast pace before the slow one. */
    static final int FAST_RETRIES = 12;
    /** Pause between the first FAST_RETRIES tries. */
    static final long FAST_RETRY_MS = 5 * 60_000L;
    /** Pause between every try after that. */
    static final long SLOW_RETRY_MS = 60 * 60_000L;

    /** True when the daemon gave no answer (null, empty or blank). NONE, GONE, DENIED and ERR-... are answers. */
    static boolean unanswered(String reply) {
        return reply == null || reply.trim().isEmpty();
    }

    /**
     * How long to wait before asking again, after {@code triesSoFar} unanswered tries. There is no give-up, on purpose:
     * a retry re-arms the same PendingIntent, which REPLACES the pending wipe alarm (on the evict-recheck path, the
     * 12-hour one), so a cap would leave the session with no alarm at all. It slows down instead.
     */
    static long retryDelayMs(int triesSoFar) {
        return triesSoFar < FAST_RETRIES ? FAST_RETRY_MS : SLOW_RETRY_MS;
    }
}
