package com.nowhere.chooser;

/**
 * NWP-20261112-10 (Q061, docs/product-decisions.md 2026-10-20) -- the decisions of the user-0 permissions live record
 * (PermsLiveRecord), kept pure java.lang so they compile alone in their suite
 * (core/vendor-common/bin/test-perms-relay-java.sh).
 *
 * The gate arms a session only on an OK GRANT-PERMS reply: a capture relayed before the login's grant would record a
 * fresh user's ungranted state over the profile's carried lines, and an ERR-* or an empty reply (the daemon
 * unreachable, or the read cap hit) leaves the session to the sign-out capture, which overwrites nothing early. A
 * permission change is relevant only when its uid belongs to the armed user, so another user's churn (the gate's own,
 * a parked session's) relays nothing. A relay goes only to the armed session while it is the current user and
 * unlocked: the receiver writes files/nowhere-perms in that user's CE storage. PER_USER_RANGE equals
 * UserHandle.PER_USER_RANGE; it is a literal so this class stays pure.
 */
final class PermsRelayGate {
    private PermsRelayGate() {}

    /** The quiet spell after the last change before the relay runs, as DozeAppsMirror's RELAY_QUIET_MS. */
    static final long QUIET_MS = 2000;

    /** UserHandle.PER_USER_RANGE: a uid's user id is uid / PER_USER_RANGE. */
    static final int PER_USER_RANGE = 100000;

    /** True when the first line of the GRANT-PERMS reply says the login's grant ran (roamd grant's "OK"). */
    static boolean armOn(String grantReplyFirstLine) {
        return grantReplyFirstLine != null && grantReplyFirstLine.startsWith("OK");
    }

    /** True when a permission change of changedUid belongs to the armed session (liveUser -1 = disarmed). */
    static boolean relevant(int changedUid, int liveUser) {
        return liveUser > 0 && changedUid / PER_USER_RANGE == liveUser;
    }

    /** True when the relay may ask the session to capture: it is the armed session, current, and unlocked. */
    static boolean mayRelay(int currentUser, int liveUser, boolean unlocked) {
        return currentUser > 0 && currentUser == liveUser && unlocked;
    }
}
