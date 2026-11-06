package com.nowhere.chooser;

/**
 * NWP-20261117-25, NWP-20261124-15: the cases for GateLookGlyph (sun(), next(), description(), shown() and the
 * owner-only key), compiled with it and GatePalette as-is by
 * core/vendor-common/bin/test-gate-look-glyph-java.sh. Every failure prints one "--- FAIL <case>: <detail>" line; the
 * exit code is 1 when any case failed.
 */
final class GateLookGlyphCases {
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

    public static void main(String[] a) {
        check("K1 sun DARK", GateLookGlyph.sun(GatePalette.DARK), "a dark gate does not show the sun");
        check("K2 sun LIGHT", !GateLookGlyph.sun(GatePalette.LIGHT), "a light gate shows the sun");
        check("K3 sun fresh", GateLookGlyph.sun(GatePalette.forLook(null)), "a fresh phone does not show the sun");
        String[] toLight = {null, "", "dark", "Light"};
        for (String s : toLight) {
            eq("K4 next(" + (s == null ? "null" : "\"" + s + "\"") + ")", GateLookGlyph.next(s), "light");
        }
        eq("K5 next(\"light\")", GateLookGlyph.next("light"), "dark");
        check("K6 description DARK", GateLookGlyph.description(GatePalette.DARK) == GateLookGlyph.TO_LIGHT,
                "got \"" + GateLookGlyph.description(GatePalette.DARK) + "\"");
        check("K6 description LIGHT", GateLookGlyph.description(GatePalette.LIGHT) == GateLookGlyph.TO_DARK,
                "got \"" + GateLookGlyph.description(GatePalette.LIGHT) + "\"");
        eq("K7 TO_LIGHT", GateLookGlyph.TO_LIGHT, "Switch to light mode");
        eq("K7 TO_DARK", GateLookGlyph.TO_DARK, "Switch to dark mode");
        String[] round = {null, "dark", "light"};
        for (String s : round) {
            check("K8 round trip", GatePalette.forLook(GateLookGlyph.next(s)) != GatePalette.forLook(s),
                    "next(" + s + ") does not switch the look");
        }
        check("K9 shown not owner-only", GateLookGlyph.shown(false), "the glyph is hidden while anyone may tap it");
        check("K9 shown owner-only", !GateLookGlyph.shown(true), "the glyph is shown while the look is owner-only");
        eq("K10 OWNER_ONLY_KEY", GateLookGlyph.OWNER_ONLY_KEY, "gate_look_owner_only");
        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("  cases ok");
    }
}
