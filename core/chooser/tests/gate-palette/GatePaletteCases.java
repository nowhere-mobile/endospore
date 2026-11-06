package com.nowhere.chooser;

/**
 * NWP-20261115-15: the cases for GatePalette, compiled with the class as-is by
 * core/vendor-common/bin/test-gate-palette-java.sh. Every failure prints one "--- FAIL <case>: <detail>" line; the exit
 * code is 1 when any case failed.
 */
final class GatePaletteCases {
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

    private static void aa(String role, int fg, String bgName, int bg) {
        double r = contrast(fg, bg);
        check("contrast " + role + " on " + bgName, r >= 4.5,
                String.format("%s on %s is %.2f:1, want >= 4.5", hex(fg), hex(bg), r));
    }

    public static void main(String[] args) {
        GatePalette d = GatePalette.DARK, l = GatePalette.LIGHT;

        // C0 the process starts dark: before any use().
        check("active before use", GatePalette.active() == d, "active() is not DARK before any use()");

        // C1 DARK is today's look, value for value.
        eq("DARK bg", d.bg, 0xFF0B0F14);
        eq("DARK ink", d.ink, 0xFFEAF1EE);
        eq("DARK muted", d.muted, 0xFF69788A);
        eq("DARK tagline", d.tagline, 0xFFDCE4EC);
        eq("DARK fieldBg", d.fieldBg, 0xFF121922);
        eq("DARK fieldLn", d.fieldLn, 0xFF232E39);
        eq("DARK hint", d.hint, 0xFF8595A4);
        eq("DARK fieldTx", d.fieldTx, 0xFFE6EDF3);
        eq("DARK accent", d.accent, 0xFF4FD6AC);
        eq("DARK onAccent", d.onAccent, 0xFF05281F);
        eq("DARK footer", d.footer, 0xFF505D69);
        eq("DARK title", d.title, 0xFFFFFFFF);
        eq("DARK help", d.help, 0xFF5FC4D4);
        eq("DARK danger", d.danger, 0xFFE05B5B);
        eq("DARK error", d.error, 0xFFE06C6C);
        eq("DARK dotOff", d.dotOff, 0xFF2B3444);
        eq("DARK callBg", d.callBg, 0xFF101418);
        eq("DARK callLabel", d.callLabel, 0xFF9AA3AD);
        eq("DARK callInk", d.callInk, 0xFFFFFFFF);
        eq("DARK callTimer", d.callTimer, 0xFF6FCF97);
        eq("DARK decline", d.decline, 0xFFE0503A);
        eq("DARK answer", d.answer, 0xFF2FA84F);
        eq("DARK neutralBtn", d.neutralBtn, 0xFF3A4048);
        eq("DARK onBtn", d.onBtn, 0xFFFFFFFF);
        check("DARK lightBars", !d.lightBars, "DARK.lightBars is true");
        check("LIGHT lightBars", l.lightBars, "LIGHT.lightBars is false");
        check("two sets", d != l, "DARK and LIGHT are the same instance");

        // C2 the stored value: LIGHT only for exactly "light".
        check("KEY", "gate_look".equals(GatePalette.KEY), "KEY is " + GatePalette.KEY);
        check("LIGHT_VALUE", "light".equals(GatePalette.LIGHT_VALUE), "LIGHT_VALUE is " + GatePalette.LIGHT_VALUE);
        check("DARK_VALUE", "dark".equals(GatePalette.DARK_VALUE), "DARK_VALUE is " + GatePalette.DARK_VALUE);
        check("forLook light", GatePalette.forLook("light") == l, "forLook(\"light\") is not LIGHT");
        check("forLook null", GatePalette.forLook(null) == d, "forLook(null) is not DARK");
        for (String s : new String[] {"", "dark", "LIGHT", "Light", " light", "light ", "light\n", "lights"}) {
            check("forLook " + s.replace("\n", "\\n").replace(" ", "<sp>"), GatePalette.forLook(s) == d,
                    "forLook(\"" + s.replace("\n", "\\n") + "\") is not DARK");
        }

        // C3 the round trip through the stored value.
        check("round trip light", GatePalette.forLook(GatePalette.valueFor(true)) == l, "valueFor(true) does not read LIGHT");
        check("round trip dark", GatePalette.forLook(GatePalette.valueFor(false)) == d, "valueFor(false) does not read DARK");

        // C4 every LIGHT text role meets WCAG AA on the light backgrounds.
        String[] roles = {"ink", "muted", "tagline", "hint", "fieldTx", "accent", "footer", "title", "help", "danger", "error"};
        int[] fg = {l.ink, l.muted, l.tagline, l.hint, l.fieldTx, l.accent, l.footer, l.title, l.help, l.danger, l.error};
        for (int i = 0; i < roles.length; i++) {
            aa(roles[i], fg[i], "bg", l.bg);
            aa(roles[i], fg[i], "fieldBg", l.fieldBg);
        }
        aa("onAccent", l.onAccent, "accent", l.accent);
        aa("callLabel", l.callLabel, "callBg", l.callBg);
        aa("callInk", l.callInk, "callBg", l.callBg);
        aa("callTimer", l.callTimer, "callBg", l.callBg);

        // C5 the call buttons are the same in both sets.
        eq("LIGHT decline", l.decline, d.decline);
        eq("LIGHT answer", l.answer, d.answer);
        eq("LIGHT neutralBtn", l.neutralBtn, d.neutralBtn);
        eq("LIGHT onBtn", l.onBtn, d.onBtn);

        // C6 use() sets the process palette; null is DARK.
        GatePalette.use(l);
        check("use LIGHT", GatePalette.active() == l, "active() is not LIGHT after use(LIGHT)");
        GatePalette.use(null);
        check("use null", GatePalette.active() == d, "active() is not DARK after use(null)");
        GatePalette.use(l);
        GatePalette.use(d);
        check("use DARK", GatePalette.active() == d, "active() is not DARK after use(DARK)");

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("  cases ok");
    }
}
