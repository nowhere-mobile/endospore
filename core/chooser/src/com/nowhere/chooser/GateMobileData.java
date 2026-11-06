package com.nowhere.chooser;

/**
 * The Owner settings "Mobile data" switch's pure decisions (NWP-20261107-13; docs/product-decisions.md, 2026-10-20,
 * "nineteen recommendations accepted (second set)", dn-1026 #5, which settled the open question of the 2026-10-19
 * mobile-data entry).
 *
 * <p>The value the owner sets here is the gate's own: roamd's md_claim records the phone's value as the baseline when
 * a session comes to the front (only when no record exists) and md_release restores it. Residual: a release that
 * failed earlier leaves a baseline record that the boot sweep restores over this value.
 *
 * <p>Pure java.lang: core/vendor-common/bin/test-gate-mobile-data-java.sh compiles this file directly.
 */
final class GateMobileData {
    private GateMobileData() {}

    static final String ROW = "Mobile data";
    static final String ROW_SUB = "The phone's own setting, used at the gate and between sessions";
    static final String NOTE = "Turns mobile data on or off for the phone itself. A profile can change it for its own session; when that session ends or goes into standby, the phone comes back to this setting.";

    /** How long the screen re-reads after a write before it gives up, and the pause between reads. */
    static final long READBACK_MS = 3000;
    static final long STEP_MS = 100;

    /** Done when the read shows the wanted value, or the bound is spent (a null read never satisfies want). */
    static boolean settled(boolean want, Boolean seen, long elapsedMs) {
        return (seen != null && seen == want) || elapsedMs >= READBACK_MS;
    }

    /** What the toast may say: only what was READ. */
    static String toast(boolean want, Boolean seen) {
        if (seen != null && seen == want) return want ? "Mobile data on" : "Mobile data off";
        return "The phone hasn't confirmed the change.";
    }
}
