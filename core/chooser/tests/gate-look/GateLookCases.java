package com.nowhere.chooser;

/**
 * NWP-20261115-16, NWP-20261124-15: the cases for GateLookCopy (eight strings), compiled with the class as-is by
 * core/vendor-common/bin/test-gate-look-java.sh. Every failure prints one "--- FAIL <case>: <detail>" line; the exit
 * code is 1 when any case failed.
 */
final class GateLookCases {
    private static int failed;

    private static void check(String name, boolean ok, String detail) {
        if (!ok) {
            System.out.println("--- FAIL " + name + ": " + detail);
            failed++;
        }
    }

    private static void eq(String name, String got, String want) {
        check(name, want.equals(got), "got \"" + got + "\", want \"" + want + "\"");
    }

    private static boolean ascii(String s) {
        if (s == null || s.isEmpty()) return false;
        for (int i = 0; i < s.length(); i++) {
            if (s.charAt(i) > 0x7E || s.charAt(i) < 0x20) return false;
        }
        return true;
    }

    public static void main(String[] a) {
        eq("C1 ROW", GateLookCopy.ROW, "Appearance");
        eq("C2 ROW_SUB", GateLookCopy.ROW_SUB, "Dark or light, for this phone's gate");
        eq("C3 INTRO", GateLookCopy.INTRO, "Dark is the default. Light changes the sign-in screen, Owner settings, the call and alarm screens, and the Profile and nApps screens inside a profile on this phone. Other apps keep their own look.");
        eq("C4 SWITCH", GateLookCopy.SWITCH, "Light mode");
        eq("C5 NOTE", GateLookCopy.NOTE, "The phone still starts on a black screen. The gate redraws when you change this, and Owner settings closes.");
        eq("C6 FAILED", GateLookCopy.FAILED, "Couldn't change that setting");
        eq("C8 OWNER_ONLY", GateLookCopy.OWNER_ONLY, "Only the owner can change the look");
        eq("C9 OWNER_ONLY_NOTE", GateLookCopy.OWNER_ONLY_NOTE, "The sun and moon on the sign-in screen are hidden, so the look changes only here.");
        String[] all = {GateLookCopy.ROW, GateLookCopy.ROW_SUB, GateLookCopy.INTRO, GateLookCopy.SWITCH,
                GateLookCopy.NOTE, GateLookCopy.FAILED, GateLookCopy.OWNER_ONLY, GateLookCopy.OWNER_ONLY_NOTE};
        for (int i = 0; i < all.length; i++) {
            check("C7 ascii", ascii(all[i]), "string " + (i + 1) + " is empty or holds a non-ASCII character");
        }
        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("  cases ok");
    }
}
