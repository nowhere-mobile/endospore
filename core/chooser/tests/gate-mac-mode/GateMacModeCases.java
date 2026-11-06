package com.nowhere.chooser;

/** Cases for GateMacMode (NWP-20261106-05): the three gate MAC choices and the setting each one writes. */
public final class GateMacModeCases {
    private static int failures = 0;

    private static void eq(String what, Object got, Object want) {
        if (!want.equals(got)) {
            System.out.println("--- FAIL " + what + ": got " + got + " want " + want);
            failures++;
        }
    }

    public static void main(String[] args) {
        eq("setting(0,100)", GateMacMode.setting(0, 100), 100);
        eq("setting(0,-1)", GateMacMode.setting(0, -1), 2);
        eq("setting(1,100)", GateMacMode.setting(1, 100), 1);
        eq("setting(1,-1)", GateMacMode.setting(1, -1), 1);
        eq("setting(2,100)", GateMacMode.setting(2, 100), 0);
        eq("setting(2,-1)", GateMacMode.setting(2, -1), 0);
        eq("setting(7,-1)", GateMacMode.setting(7, -1), 2);
        eq("setting(-1,100)", GateMacMode.setting(-1, 100), 100);
        eq("DEFAULT", GateMacMode.DEFAULT, 0);
        eq("NONE", GateMacMode.NONE, 0);
        eq("PERSISTENT", GateMacMode.PERSISTENT, 1);
        eq("NON_PERSISTENT", GateMacMode.NON_PERSISTENT, 2);
        eq("LABELS.length", GateMacMode.LABELS.length, 3);
        eq("LABELS[0]", GateMacMode.LABELS[0], "New private address each connection (default)");
        eq("LABELS[1]", GateMacMode.LABELS[1], "Same private address for this network");
        eq("LABELS[2]", GateMacMode.LABELS[2], "This phone's real MAC");
        eq("HINT", GateMacMode.HINT,
                "Randomized hides this phone's hardware address. The network can still recognise this phone.");
        if (failures > 0) System.exit(1);
        System.out.println("ok: GateMacMode labels, hint and settings");
    }
}
