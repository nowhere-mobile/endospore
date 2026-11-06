package com.nowhere.chooser;

/**
 * NWP-20261117-21: the cases for the roles the Profile screen draws from, compiled with GatePalette as-is by
 * core/vendor-common/bin/test-profile-look-java.sh. Every failure prints one "--- FAIL <case>: <detail>" line; the
 * exit code is 1 when any case failed.
 */
final class ProfileLookCases {
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
        check(name, r >= 4.5, String.format("%s on %s is %.2f:1, want >= 4.5", hex(fg), hex(bg), r));
    }

    public static void main(String[] args) {
        GatePalette d = GatePalette.DARK, l = GatePalette.LIGHT;

        // K1 the Global key a session reads, byte for byte.
        check("K1 GLOBAL_KEY", "nowhere.gate_look".equals(GatePalette.GLOBAL_KEY),
                "GLOBAL_KEY is \"" + GatePalette.GLOBAL_KEY + "\", want \"nowhere.gate_look\"");

        // K2 the new DARK roles are today's ProfileActivity literals, value for value.
        eq("K2 DARK panel", d.panel, 0xFF121821);
        eq("K2 DARK panelLn", d.panelLn, 0xFF232C36);
        eq("K2 DARK warn", d.warn, 0xFFE0A34F);
        eq("K2 DARK outline", d.outline, 0x33FFFFFF);
        eq("K2 DARK qrDark", d.qrDark, 0xFF000000);
        eq("K2 DARK qrLight", d.qrLight, 0xFFFFFFFF);

        // K3 a QR code is black on white in both sets.
        eq("K3 qrDark same in both sets", l.qrDark, d.qrDark);
        eq("K3 qrLight same in both sets", l.qrLight, d.qrLight);

        // K4 the amber warning lines read on the page and on a field.
        aa("K4 LIGHT warn on bg", l.warn, l.bg);
        aa("K4 LIGHT warn on fieldBg", l.warn, l.fieldBg);

        // K5 text on a note panel or a segmented track; the panel stands apart from the page.
        aa("K5 LIGHT ink on panel", l.ink, l.panel);
        aa("K5 LIGHT muted on panel", l.muted, l.panel);
        check("K5 LIGHT panel differs from bg", l.panel != l.bg, "LIGHT.panel equals LIGHT.bg " + hex(l.bg));

        // K6 a selected segment draws bg text on accent.
        aa("K6 LIGHT bg on accent", l.bg, l.accent);

        // K7 the delete button's label: onBtn on danger.
        aa("K7 LIGHT onBtn on danger", l.onBtn, l.danger);

        // K8 a chip's outline is a 20 % line of the set's ink side.
        eq("K8 LIGHT outline", l.outline, 0x33000000);

        // K9 withAlpha keeps the colour and takes only the low byte of the alpha.
        eq("K9 withAlpha", GatePalette.withAlpha(0xFF4FD6AC, 0x22), 0x224FD6AC);
        eq("K9 withAlpha low byte", GatePalette.withAlpha(0x00123456, 0x1FF), 0xFF123456);

        if (failed > 0) System.exit(1);
        System.out.println("  cases ok");
    }
}
