package com.nowhere.napps;

/**
 * NWP-20261117-31: nApps' two palettes and the rule that picks one (docs/product-decisions.md, 2026-10-29, "Profile
 * and nApps follow the gate's light/dark look"). The gate's choice reaches a session as the Global setting GLOBAL_KEY
 * (ChooserActivity.mirrorGateLook, NWP-20261117-21). This APK depends on the chooser for data only, so the key and the
 * colours are restated here, not shared; test-napps-look-java.sh pins GLOBAL_KEY equal to GatePalette.GLOBAL_KEY.
 * DARK is the old look, value for value; every LIGHT text role meets WCAG AA (4.5:1) on the LIGHT bg, pinned by
 * NappsLookCases. Pure java.lang, so the cases compile it as-is.
 */
final class NappsLook {
    static final String GLOBAL_KEY = "nowhere.gate_look";
    static final String LIGHT_VALUE = "light";

    final int bg, ink, muted, accent, warn;

    private NappsLook(boolean light) {
        // role = light ?    LIGHT   :    DARK      // the GatePalette.LIGHT role it takes
        bg     = light ? 0xFFF6F8FA : 0xFF0E1214;   // bg
        ink    = light ? 0xFF16202A : 0xFFEAF2F2;   // ink
        muted  = light ? 0xFF5A6878 : 0xFF8FA3A6;   // muted
        accent = light ? 0xFF087658 : 0xFF4FD1C5;   // accent
        warn   = light ? 0xFF8A5A00 : 0xFFB0812E;   // warn
    }

    static final NappsLook DARK = new NappsLook(false);
    static final NappsLook LIGHT = new NappsLook(true);

    /** True only for exactly "light": no trim, no case folding. Anything else, null included, is dark. */
    static boolean light(String stored) {
        return LIGHT_VALUE.equals(stored);
    }
}
