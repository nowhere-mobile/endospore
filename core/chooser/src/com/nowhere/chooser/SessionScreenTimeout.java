package com.nowhere.chooser;

/**
 * NWP-20261113-13 (Q073, docs/product-decisions.md 2026-10-20): a new session (the Android user a sign-in or a create
 * makes) turns its screen off after {@link #NEW_SESSION_MS} (1 min, AOSP's own default), whatever the platform or an
 * overlay would give it. It is written before applyRoamedPrefs, so the user's own value, captured at seal and applied
 * at sign-in by the Q012 capture, wins over it; that capture is not here. A cold-lock resume reuses its user and is
 * not rewritten. Pure java.lang so the suite compiles this file as-is.
 */
final class SessionScreenTimeout {
    private SessionScreenTimeout() {}

    /** A new session's screen-off timeout, in milliseconds. */
    static final int NEW_SESSION_MS = 60_000;

    /** True when {@code current} is not a new session's value; a read that failed reaches here as -1 and is written. */
    static boolean needsWrite(int current) {
        return current != NEW_SESSION_MS;
    }
}
