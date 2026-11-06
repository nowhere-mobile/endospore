package com.nowhere.chooser;

import java.util.Map;
import java.util.Objects;

/**
 * NWP-20261125-22: did a settings write land?
 *
 * Profile > Configuration's media and app defaults (cfgPut) and the Auto-wipe picker never learned that their write
 * failed: cfgPut is void and logs a failed StoreInstaller.writeAtomic, so the segment kept the new choice, the wipe
 * toast said "applies next sign-in", and presetGuard saved (or, on Replace, replaced) the Custom preset from a change
 * the profile did not have. Each of them now reads its files back after the write (ProfileActivity.presetCurrent, in
 * the representation the screens pass to PresetPicker.change) and asks this class whether the change is there.
 *
 * Its own loop, not PresetPicker.unchanged: presetGuard holds no decision of PresetPicker's but guardAction's
 * (test-preset-picker-java.sh P8). Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-setting-landed-java.sh).
 */
final class SettingLanded {
    private SettingLanded() {}

    /** What a screen says when its write did not land. It claims nothing was saved or will apply. */
    static final String NOT_SAVED = "Couldn't save that change — nothing changed. Try again.";

    /** True when every key of change is in after with an equal value. A null change or after is false; an empty
     *  change is true. */
    static boolean landed(Map<String, String> change, Map<String, String> after) {
        if (change == null || after == null) return false;
        for (Map.Entry<String, String> e : change.entrySet()) {
            if (!after.containsKey(e.getKey())) return false;
            if (!Objects.equals(e.getValue(), after.get(e.getKey()))) return false;
        }
        return true;
    }
}
