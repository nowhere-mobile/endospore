package com.nowhere.chooser;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** NWP-20261125-22: the settings read-back's pure half (SettingLanded), run by
 *  core/vendor-common/bin/test-setting-landed-java.sh. Exit 1 on any failed case. */
final class SettingLandedCases {
    private static int fails = 0;

    private static void check(boolean ok, String name) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + name);
        if (!ok) fails++;
    }

    private static Map<String, String> m(String... kv) {
        Map<String, String> out = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) out.put(kv[i], kv[i + 1]);
        return out;
    }

    /** The current map of a profile whose files hold v for key, written the way that row's screen writes it. */
    private static Map<String, String> holding(String key, String v) {
        String prefs = "", config = "", reclaim = "";
        if (key.equals("idle")) prefs = "idle=" + v + "\n";
        // holdaudio= (NWP-20261124-17) lives in the prefs file exactly like holdlock=: empty = On, "0" = Off.
        else if (key.equals("holdlock") || key.equals("holdaudio")) prefs = v.isEmpty() ? "" : key + "=" + v + "\n";
        else if (key.equals("wipe")) {
            int i = Integer.parseInt(v);
            prefs = "wipe=" + WipeChoice.wipeValue(i) + "\n"
                    + ("1".equals(WipeChoice.savedValue(i)) ? WipeOnSave.PREF + "=1\n" : "");
        } else if (key.equals("reclaim")) reclaim = v + "\n";
        else config = key + "=" + v + "\n";
        return PresetPicker.current(prefs, config, reclaim);
    }

    public static void main(String[] args) {
        // L1 equal: every key of change is in after with the same value; extra keys in after do not matter.
        check(SettingLanded.landed(m("a", "1", "b", "2"), m("a", "1", "b", "2", "c", "3")), "L1 equal");

        // L2 one key differs.
        check(!SettingLanded.landed(m("a", "1", "b", "2"), m("a", "1", "b", "9")), "L2 one key differs");

        // L3 key missing, a null value included.
        check(!SettingLanded.landed(m("a", "1"), m("b", "1")), "L3 key missing");
        check(!SettingLanded.landed(m("a", null), Collections.<String, String>emptyMap()),
                "L3 key missing with a null change value");

        // L4 null.
        check(!SettingLanded.landed(null, m()), "L4 null change");
        check(!SettingLanded.landed(m("a", "1"), null), "L4 null after");
        check(!SettingLanded.landed(m(), null), "L4 empty change, null after");
        check(!SettingLanded.landed(null, null), "L4 both null");

        // L5 empty change.
        check(SettingLanded.landed(m(), m()), "L5 empty change, empty after");
        check(SettingLanded.landed(m(), m("a", "1")), "L5 empty change");

        // L6 NOT_SAVED claims nothing.
        String ns = SettingLanded.NOT_SAVED;
        check(ns != null && !ns.trim().isEmpty(), "L6 NOT_SAVED is not empty");
        check(ns != null && !ns.contains("Saved") && !ns.contains("applies"),
                "L6 NOT_SAVED says neither Saved nor applies");

        // L7 for every row and option, the read-back agrees with PresetPicker.unchanged over the same files.
        for (ProfilePresets.Row r : ProfilePresets.ROWS) {
            for (String v : r.optionValues) {
                Map<String, String> after;
                try {
                    after = holding(r.key, v);
                } catch (RuntimeException e) {
                    check(false, "L7 " + r.key + "=" + v + ": current cannot read it (" + e + ")");
                    continue;
                }
                Map<String, String> c = PresetPicker.change(r.key, v);
                check(SettingLanded.landed(c, after), "L7 " + r.key + "=" + v + " landed when the file holds it");
                check(SettingLanded.landed(c, after) == PresetPicker.unchanged(after, c),
                        "L7 " + r.key + "=" + v + " agrees with unchanged");
                for (String v2 : r.optionValues) {
                    if (v2.equals(v)) continue;
                    Map<String, String> c2 = PresetPicker.change(r.key, v2);
                    check(!SettingLanded.landed(c2, after),
                            "L7 " + r.key + "=" + v2 + " not landed when the file holds " + v);
                    check(SettingLanded.landed(c2, after) == PresetPicker.unchanged(after, c2),
                            "L7 " + r.key + "=" + v2 + " over " + v + " agrees with unchanged");
                }
            }
        }

        // L8 the Configuration lambdas read back the screen value: one current can return for its row.
        ProfilePresets.Row media = null;
        for (ProfilePresets.Row r : ProfilePresets.ROWS) if (r.key.equals("media.default")) media = r;
        check(media != null && media.optionValues.containsAll(PresetPicker.MEDIA_SCREEN_VALUES),
                "L8 every MEDIA_SCREEN_VALUES entry is a media.default option");
        boolean appdef = false;
        for (ProfilePresets.Row r : ProfilePresets.ROWS) {
            if (!r.key.startsWith("apps.default.")) continue;
            appdef = true;
            check(r.optionValues.containsAll(PresetPicker.APPDEF_SCREEN_VALUES),
                    "L8 every APPDEF_SCREEN_VALUES entry is a " + r.key + " option");
        }
        check(appdef, "L8 ROWS has apps.default rows");

        if (fails > 0) {
            System.out.println(fails + " case(s) failed");
            System.exit(1);
        }
    }
}
