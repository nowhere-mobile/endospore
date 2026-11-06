package com.nowhere.chooser;

/**
 * NWP-20261117-35: the cases for the QR scan screen's three GatePalette roles, compiled with the class as-is by
 * core/vendor-common/bin/test-gate-dialogs-java.sh. A camera viewfinder keeps its dark surround in both looks, so each
 * role is the same in DARK and LIGHT and equals the literal QrScanActivity drew before. Every failure prints one
 * "--- FAIL <case>: <detail>" line; the exit code is 1 when any case failed.
 */
final class GateDialogCases {
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

    public static void main(String[] args) {
        GatePalette d = GatePalette.DARK, l = GatePalette.LIGHT;

        // D1-D3 each scan role is the old QrScanActivity literal, in both sets.
        eq("DARK scanBg", d.scanBg, 0xFF0B0F14);
        eq("LIGHT scanBg", l.scanBg, 0xFF0B0F14);
        eq("DARK scanInk", d.scanInk, 0xFFFFFFFF);
        eq("LIGHT scanInk", l.scanInk, 0xFFFFFFFF);
        eq("DARK scanShadow", d.scanShadow, 0xCC000000);
        eq("LIGHT scanShadow", l.scanShadow, 0xCC000000);

        // D4 the hint reads on the viewfinder surround (WCAG AA) in both sets.
        for (GatePalette p : new GatePalette[] {d, l}) {
            String set = p == d ? "DARK" : "LIGHT";
            double r = contrast(p.scanInk, p.scanBg);
            check("contrast scanInk on scanBg " + set, r >= 4.5,
                    String.format("%s on %s is %.2f:1, want >= 4.5", hex(p.scanInk), hex(p.scanBg), r));
        }

        if (failed == 0) System.out.println("  cases ok");
        System.exit(failed == 0 ? 0 : 1);
    }
}
