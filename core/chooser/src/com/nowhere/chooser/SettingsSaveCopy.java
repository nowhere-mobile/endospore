package com.nowhere.chooser;

/**
 * What the Offline media and Re-archive settings say when a change was not saved (NWP-20261124-23). Their writers
 * return whether the file now holds the choice; on false the control says so and shows what the file holds. The
 * words claim no change: after a partial per-app tier failure one of its two files did change, so they do not say
 * "nothing changed" either. java.lang only, so core/vendor-common/bin/test-settings-save-java.sh can run it.
 */
final class SettingsSaveCopy {
    private SettingsSaveCopy() {}

    /** The toast a control shows when its write failed (a full /data, a temp that cannot be renamed). */
    static final String NOT_SAVED = "Couldn't save that change — this phone's storage may be full.";

    /** A per-app tier is saved only when both nowhere-pins and nowhere-media-tiers hold it: the seal reads both. */
    static boolean tierSaved(boolean pinOk, boolean tierOk) {
        return pinOk && tierOk;
    }
}
