package com.nowhere.chooser;

/**
 * NWP-20261117-29: the cases for GatePalette's switch roles, compiled with the class as-is by
 * core/vendor-common/bin/test-gate-switch-java.sh. WCAG 2.1 1.4.11 asks 3:1 of the parts that show a control's state;
 * the platform's track drawable keeps its own transparency, so each LIGHT knob carries the 3:1 on bg and on fieldBg.
 * Every failure prints one "--- FAIL <case>: <detail>" line; the exit code is 1 when any case failed.
 */
final class GateSwitchCases {
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

    // WCAG 2.x relative luminance of an opaque sRGB colour (GatePaletteCases' rule, restated).
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

    private static void nonText(String role, int fg, String bgName, int bg) {
        double r = contrast(fg, bg);
        check("contrast " + role + " on " + bgName, r >= 3.0,
                String.format("%s on %s is %.2f:1, want >= 3.0", hex(fg), hex(bg), r));
    }

    private static void opaque(String role, int c) {
        check("opaque " + role, (c >>> 24) == 0xFF, hex(c) + " has alpha " + (c >>> 24) + ", want 255");
    }

    public static void main(String[] args) {
        GatePalette d = GatePalette.DARK, l = GatePalette.LIGHT;

        // C1 each LIGHT knob meets 3:1 on the page and on a field, and is opaque (the rule ignores alpha).
        nonText("switchThumbOff", l.switchThumbOff, "bg", l.bg);
        nonText("switchThumbOff", l.switchThumbOff, "fieldBg", l.fieldBg);
        nonText("switchThumbOn", l.switchThumbOn, "bg", l.bg);
        nonText("switchThumbOn", l.switchThumbOn, "fieldBg", l.fieldBg);
        opaque("switchThumbOff", l.switchThumbOff);
        opaque("switchThumbOn", l.switchThumbOn);

        // C2 on and off are told apart by colour, not only by the knob's side.
        check("thumb on differs from off", l.switchThumbOn != l.switchThumbOff,
                "LIGHT switchThumbOn and switchThumbOff are both " + hex(l.switchThumbOn));

        // C3 the existing DARK roles are unchanged, and only LIGHT reads lightBars (GateSwitch.style keys on it).
        eq("DARK bg", d.bg, 0xFF0B0F14);
        eq("DARK accent", d.accent, 0xFF4FD6AC);
        eq("DARK onBtn", d.onBtn, 0xFFFFFFFF);
        check("DARK lightBars", !d.lightBars, "DARK.lightBars is true");
        check("LIGHT lightBars", l.lightBars, "LIGHT.lightBars is false");

        if (failed > 0) System.exit(1);
        System.out.println("  cases ok");
    }
}
