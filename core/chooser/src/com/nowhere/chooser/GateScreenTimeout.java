package com.nowhere.chooser;

/**
 * NWP-20261106-18 (Q073, docs/product-decisions.md 2026-10-20): the gate (user 0) turns its screen off after
 * {@link #GATE_MS} (30 s) on every phone, whatever setup, an owner's Settings visit or the platform left in
 * {@code screen_off_timeout}. This is the GATE half only: a new session's 1 min is SessionScreenTimeout
 * (NWP-20261113-13), and the user's own value, captured at seal and applied at sign-in, belongs to the Q012 capture.
 * Pure java.lang so the suite compiles this file as-is.
 */
final class GateScreenTimeout {
    private GateScreenTimeout() {}

    /** The gate's screen-off timeout, in milliseconds. */
    static final int GATE_MS = 30_000;

    /** True when {@code current} is not the gate's value; a read that failed reaches here as -1 and is written. */
    static boolean needsWrite(int current) {
        return current != GATE_MS;
    }
}
