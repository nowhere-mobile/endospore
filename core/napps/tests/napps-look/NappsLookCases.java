package com.nowhere.napps;

/**
 * NWP-20261117-31: the cases for nApps' two palettes and the rule that picks one, compiled with NappsLook as-is by
 * core/vendor-common/bin/test-napps-look-java.sh. Every failure prints one "--- FAIL <case>: <detail>" line; the exit
 * code is 1 when any case failed.
 */
final class NappsLookCases {
    private static int failed;

    private static void check(String name, boolean ok, String detail) {
        if (!ok) {
            System.out.println("--- FAIL " + name + ": " + detail);
            failed++;
        }
    }

    private static String hex(int c) {
        return String.format("#%06X", c & 0xFFFFFF);
    }

    private static void eq(String name, int got, int want) {
        check(name, got == want, "got " + hex(got) + " (alpha " + (got >>> 24) + "), want " + hex(want)
                + " (alpha " + (want >>> 24) + ")");
    }

    // WCAG 2.x relative luminance of an opaque sRGB colour.
    private static double lin(int c8) {
        double c = c8 / 255.0;
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }

    private static double luminance(int c) {
        return 0.2126 * lin((c >> 16) & 0xFF) + 0.7152 * lin((c >> 8) & 0xFF) + 0.0722 * lin(c & 0xFF);
    }

    static double contrast(int a, int b) {
        double la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    private static void aa(String name, int fg, int bg) {
        double r = contrast(fg, bg);
        System.out.println(String.format("  %s: %s on %s is %.2f:1", name, hex(fg), hex(bg), r));
        check(name, r >= 4.5, String.format("%s on %s is %.2f:1, want >= 4.5", hex(fg), hex(bg), r));
    }

    private static void opaque(String name, int c) {
        check(name, (c >>> 24) == 0xFF, hex(c) + " has alpha " + (c >>> 24) + ", want 255");
    }

    public static void main(String[] args) {
        NappsLook d = NappsLook.DARK, l = NappsLook.LIGHT;

        // K1 the Global key the gate mirrors its look to (GatePalette.GLOBAL_KEY), byte for byte.
        check("K1 GLOBAL_KEY", "nowhere.gate_look".equals(NappsLook.GLOBAL_KEY),
                "GLOBAL_KEY is \"" + NappsLook.GLOBAL_KEY + "\", want \"nowhere.gate_look\"");
        // K2 the one value that reads light.
        check("K2 LIGHT_VALUE", "light".equals(NappsLook.LIGHT_VALUE),
                "LIGHT_VALUE is \"" + NappsLook.LIGHT_VALUE + "\", want \"light\"");

        // L1 exactly "light" is light; L2 anything else, null included, is dark: no trim, no case folding.
        check("L1 light(\"light\")", NappsLook.light("light"), "is dark, want light");
        String[] dark = {null, "", "Light", " light", "light ", "dark", "LIGHT"};
        for (String s : dark) {
            check("L2 light(" + (s == null ? "null" : "\"" + s + "\"") + ")", !NappsLook.light(s), "is light, want dark");
        }

        // D1 DARK is the old look, value for value (StoreActivity's five literals before NWP-20261117-31).
        eq("D1 DARK bg", d.bg, 0xFF0E1214);
        eq("D1 DARK ink", d.ink, 0xFFEAF2F2);
        eq("D1 DARK muted", d.muted, 0xFF8FA3A6);
        eq("D1 DARK accent", d.accent, 0xFF4FD1C5);
        eq("D1 DARK warn", d.warn, 0xFFB0812E);

        // A1 every LIGHT text role meets WCAG AA (4.5:1) on the LIGHT bg.
        aa("A1 LIGHT ink on bg", l.ink, l.bg);
        aa("A1 LIGHT muted on bg", l.muted, l.bg);
        aa("A1 LIGHT accent on bg", l.accent, l.bg);
        aa("A1 LIGHT warn on bg", l.warn, l.bg);

        // A2 every LIGHT value is opaque, so the A1 ratios are honest.
        opaque("A2 LIGHT bg", l.bg);
        opaque("A2 LIGHT ink", l.ink);
        opaque("A2 LIGHT muted", l.muted);
        opaque("A2 LIGHT accent", l.accent);
        opaque("A2 LIGHT warn", l.warn);

        if (failed > 0) {
            System.out.println("  " + failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("  cases ok");
    }
}
