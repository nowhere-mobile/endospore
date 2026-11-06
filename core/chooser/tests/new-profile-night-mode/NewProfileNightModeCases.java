package com.nowhere.chooser;

/** Cases for NewProfileNightMode (NWP-20261124-18, #14). Exits 1 on any failure. */
public class NewProfileNightModeCases {
    private static int failures = 0;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    public static void main(String[] args) {
        check("MODE_NO is 1 (UiModeManager.MODE_NIGHT_NO)", NewProfileNightMode.MODE_NO == 1);
        check("MODE_YES is 2 (UiModeManager.MODE_NIGHT_YES)", NewProfileNightMode.MODE_YES == 2);
        check("SETTING is ui_night_mode", "ui_night_mode".equals(NewProfileNightMode.SETTING));
        check("light is 1", NewProfileNightMode.value("light") == 1);
        check("dark is 2", NewProfileNightMode.value("dark") == 2);
        check("absent (null) is 2", NewProfileNightMode.value(null) == 2);
        check("empty is 2", NewProfileNightMode.value("") == 2);
        check("Light (case) is 2", NewProfileNightMode.value("Light") == 2);
        check("' light' (space) is 2", NewProfileNightMode.value(" light") == 2);
        check("GatePalette.valueFor(true) is 1", NewProfileNightMode.value(GatePalette.valueFor(true)) == 1);
        check("GatePalette.valueFor(false) is 2", NewProfileNightMode.value(GatePalette.valueFor(false)) == 2);
        if (failures > 0) System.exit(1);
        System.out.println("  cases ok");
    }
}
