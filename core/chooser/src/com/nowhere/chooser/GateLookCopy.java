package com.nowhere.chooser;

/**
 * NWP-20261115-16: the words of Owner settings › Appearance (docs/product-decisions.md, 2026-10-26), which holds the
 * owner-only switch (NWP-20261124-15, 2026-11-02 #11). The Light mode switch and its words are gone (NWP-20261130-13,
 * 2026-11-06); the gate's sun/moon is the only light/dark control. Pure java.lang, so GateLookCases
 * (core/chooser/tests/gate-look) compiles it as-is and pins every string byte for byte.
 */
final class GateLookCopy {
    private GateLookCopy() {}

    static final String ROW = "Appearance";
    static final String ROW_SUB = "Who can change this phone's look";
    static final String INTRO = "Dark is the default. The sun and moon on the sign-in screen switch between dark and light. Light changes the sign-in screen, Owner settings, the call and alarm screens, and the Profile and nApps screens inside a profile on this phone. Other apps keep their own look. The phone still starts on a black screen.";
    static final String FAILED = "Couldn't change that setting";
    static final String OWNER_ONLY = "Only the owner can change the look";
    static final String OWNER_ONLY_NOTE = "The sun and moon on the sign-in screen are hidden, so the look stays as it is. To change the look, turn this off. The gate redraws when you change this, and Owner settings closes.";
}
