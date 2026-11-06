package com.nowhere.chooser;

/**
 * NWP-20261110-23: the battery rule for the background re-key, lifted out of ChooserActivity so it runs under javac.
 *
 * The decision (docs/product-decisions.md, the tie job's "Battery" bullet, NWP-20261008-03): the re-key "pauses while
 * the battery is under 20% and not charging". "Not charging" means the battery status is neither CHARGING nor FULL,
 * not that the phone is unplugged (#65, 2026-10-22, "seventy-two recommendations accepted, and three more answers
 * ...", NWP-20261022-31; built by NWP-20261117-19): a plugged-in phone that still discharges under 20% waits.
 * A battery state that cannot be read (no level, no scale, no status) answers false: the re-key waits.
 */
final class RekeyBattery {
    private RekeyBattery() {}

    /** The lowest charge percentage at which a device that is not charging may run the re-key. */
    static final int MIN_PCT = 20;

    /** android.os.BatteryManager.BATTERY_STATUS_CHARGING and BATTERY_STATUS_FULL, mirrored to keep this java.* only. */
    static final int STATUS_CHARGING = 2;
    static final int STATUS_FULL = 5;

    static boolean allows(int level, int scale, int status) {
        if (status == STATUS_CHARGING || status == STATUS_FULL) return true;
        return level >= 0 && scale > 0 && level * 100 >= MIN_PCT * scale;
    }
}
