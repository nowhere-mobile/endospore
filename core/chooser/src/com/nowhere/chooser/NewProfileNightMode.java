package com.nowhere.chooser;

/**
 * NWP-20261124-18: a new profile's Android dark-theme setting starts from the gate's look (docs/product-decisions.md,
 * 2026-11-02, #14, option A). Pure java.lang, so the cases compile it as-is with GatePalette.java
 * (core/chooser/tests/new-profile-night-mode).
 *
 * ChooserActivity.ensureCreateNightMode() writes value(gate_look) into the new user's Settings.Secure SETTING once, at
 * a profile's Create, before switch-in. A sign-in never writes it, so after creation the profile's own setting wins.
 * The gate's look is device-wide, so the write reveals no profile. The setting does not roam yet (docs/backlog.md
 * section B, "Per-user Secure and System settings rows do not roam"), so a later sign-in starts from Android's default.
 */
final class NewProfileNightMode {
    private NewProfileNightMode() {}

    /** UiModeManager.MODE_NIGHT_NO and MODE_NIGHT_YES: the values Settings.Secure "ui_night_mode" holds. */
    static final int MODE_NO = 1;
    static final int MODE_YES = 2;
    /** The Secure row UiModeManagerService reads for a user (Settings.Secure.UI_NIGHT_MODE, @hide). */
    static final String SETTING = "ui_night_mode";

    /** MODE_NO only for exactly GatePalette.LIGHT_VALUE; anything else, null and "" included, is MODE_YES: a fresh
     *  phone's gate is dark (GatePalette.forLook). */
    static int value(String gateLook) {
        return GatePalette.LIGHT_VALUE.equals(gateLook) ? MODE_NO : MODE_YES;
    }
}
