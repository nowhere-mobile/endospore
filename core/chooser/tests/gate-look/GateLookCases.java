package com.nowhere.chooser;

/**
 * NWP-20261115-16, NWP-20261124-15, NWP-20261130-13: the cases for GateLookCopy (six strings), compiled with the class
 * as-is by core/vendor-common/bin/test-gate-look-java.sh. Every failure prints one "--- FAIL <case>: <detail>" line; the
 * exit code is 1 when any case failed.
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

    public static void main(String[] a) throws IllegalAccessException {
        eq("C1 ROW", GateLookCopy.ROW, "Appearance");
        eq("C2 ROW_SUB", GateLookCopy.ROW_SUB, "Who can change this phone's look");
        eq("C3 INTRO", GateLookCopy.INTRO, "Dark is the default. The sun and moon on the sign-in screen switch between dark and light. Light changes the sign-in screen, Owner settings, the call and alarm screens, and the Profile and nApps screens inside a profile on this phone. Other apps keep their own look. The phone still starts on a black screen.");
        eq("C6 FAILED", GateLookCopy.FAILED, "Couldn't change that setting");
        eq("C8 OWNER_ONLY", GateLookCopy.OWNER_ONLY, "Only the owner can change the look");
        eq("C9 OWNER_ONLY_NOTE", GateLookCopy.OWNER_ONLY_NOTE, "The sun and moon on the sign-in screen are hidden, so the look stays as it is. To change the look, turn this off. The gate redraws when you change this, and Owner settings closes.");
        // NWP-20261130-13: the Light mode switch and its note are gone. By reflection, because a direct reference would
        // not compile against the fixed class.
        for (java.lang.reflect.Field f : GateLookCopy.class.getDeclaredFields()) {
            check("C10 no light switch copy", !f.getName().equals("SWITCH") && !f.getName().equals("NOTE"), "GateLookCopy holds " + f.getName());
            if (f.getType() == String.class) {
                check("C10 no light switch copy", !"Light mode".equals(f.get(null)), f.getName() + " is the removed switch's words");
            }
        }
        String[] all = {GateLookCopy.ROW, GateLookCopy.ROW_SUB, GateLookCopy.INTRO, GateLookCopy.FAILED,
                GateLookCopy.OWNER_ONLY, GateLookCopy.OWNER_ONLY_NOTE};
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
