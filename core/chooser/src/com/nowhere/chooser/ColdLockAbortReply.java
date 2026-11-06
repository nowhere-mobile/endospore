package com.nowhere.chooser;

/**
 * NWP-20261124-04: what the gate does with the daemon's COLD-LOCK-ABORT reply. An unlock after an idle cold lock has
 * committed used to read "OK" like a real abort, so the owner used a session that was about to lock. The daemon now
 * answers COMMITTED for that case; the gate then covers the session ("Locking…") until the daemon's own SWITCH lands.
 * Pure (java.* only), so test-coldlock-abort-reply-java.sh compiles it alone.
 */
final class ColdLockAbortReply {
    enum Action {
        /** The abort armed, or a rejection the daemon answers OK: nothing to do. */
        ABORTED,
        /** The lock this session is in has committed: cover the session until the switch to the gate. */
        COVER,
        /** No reply, an error, or a reply this gate does not know. */
        NONE
    }

    private ColdLockAbortReply() {}

    static Action afterReply(String reply) {
        String r = reply == null ? "" : reply.trim();
        if ("OK".equals(r)) return Action.ABORTED;
        if ("COMMITTED".equals(r)) return Action.COVER;
        return Action.NONE;
    }
}
