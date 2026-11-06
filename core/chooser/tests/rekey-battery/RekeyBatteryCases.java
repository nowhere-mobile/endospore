package com.nowhere.chooser;

/** NWP-20261110-23: the re-key's battery rule. Exit 0 when every case holds, 1 otherwise. */
public final class RekeyBatteryCases {
    private static int bad = 0;

    private static void check(String label, boolean want, int level, int scale, int status) {
        boolean got = RekeyBattery.allows(level, scale, status);
        if (got != want) {
            System.out.println("  FAIL  " + label + ": allows(" + level + "," + scale + "," + status + ") = " + got
                    + ", want " + want);
            bad++;
        } else {
            System.out.println("  ok    " + label);
        }
    }

    public static void main(String[] args) {
        // B1: the 20% line, on the percent scale and on a coarse one.
        check("B1 19% unplugged waits", false, 19, 100, 0);
        check("B1 20% unplugged runs", true, 20, 100, 0);
        check("B1 1 of 5 (20%) runs", true, 1, 5, 0);
        check("B1 0 of 5 waits", false, 0, 5, 0);
        // B2: an unreadable state waits.
        check("B2 zero scale waits", false, 50, 0, 0);
        check("B2 negative level waits", false, -1, 100, 0);
        // B3: the battery status decides "charging" (#65, 2026-10-22), not EXTRA_PLUGGED. CHARGING (2) and FULL (5)
        // run at any level; DISCHARGING (3), NOT_CHARGING (4) and UNKNOWN (1) fall to the 20% line, so a plugged-in
        // phone that is discharging under 20% pauses.
        check("B3 charging at 5% runs", true, 5, 100, 2);
        check("B3 full at 5% runs", true, 5, 100, 5);
        check("B3 charging with no reading runs", true, -1, -1, 2);
        check("B3 discharging at 10% waits (plugged in, weak charger)", false, 10, 100, 3);
        check("B3 not charging at 10% waits (plugged in, weak charger)", false, 10, 100, 4);
        check("B3 unknown status at 10% waits", false, 10, 100, 1);
        check("B3 discharging at 20% runs", true, 20, 100, 3);
        if (bad != 0) {
            System.out.println(bad + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases ok");
    }
}
