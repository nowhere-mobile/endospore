package com.nowhere.chooser;

/**
 * The gate Settings "Airplane mode" switch's pure decisions (NWP-20261109-21; docs/product-decisions.md, 2026-10-20,
 * "twenty-eight recommendations accepted", Q072, its changed recommendation).
 *
 * <p>The value the owner sets here is the gate's own: roamd's dtclaim records the phone's airplane value as the
 * baseline when the next session first comes to the front (only when no record exists) and dtrelease restores it at
 * that session's release. Residual: while a session's record exists (a parked session), its release puts the
 * recorded value back over a flip made here.
 *
 * <p>Pure java.lang: core/vendor-common/bin/test-gate-airplane-java.sh compiles this file directly.
 */
final class GateAirplane {
    private GateAirplane() {}

    static final String ROW = "Airplane mode";
    static final String SUB = "A sign-in in airplane mode is an offline session";

    /** How long the screen re-reads after a write before it gives up, and the pause between reads. */
    static final long READBACK_MS = 3000;
    static final long STEP_MS = 100;

    /** Done when the read shows the wanted value, or the bound is spent (a null read never satisfies want). */
    static boolean settled(boolean want, Boolean seen, long elapsedMs) {
        return (seen != null && seen == want) || elapsedMs >= READBACK_MS;
    }

    /** What the result line may say: only what was READ. */
    static String toast(boolean want, Boolean seen) {
        if (seen != null && seen == want) return want ? "Airplane mode on" : "Airplane mode off";
        return "The phone didn't confirm the change";
    }
}
