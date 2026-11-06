package com.nowhere.chooser;

/**
 * NWP-20261115-16: the words of the gate's Light mode switch (Owner settings, Appearance; docs/product-decisions.md,
 * 2026-10-26), and of the owner-only switch below it (NWP-20261124-15, 2026-11-02 #11). Pure java.lang, so
 * GateLookCases (core/chooser/tests/gate-look) compiles it as-is and pins every string byte for byte.
 */
final class GateLookCopy {
    private GateLookCopy() {}

    static final String ROW = "Appearance";
    static final String ROW_SUB = "Dark or light, for this phone's gate";
    static final String INTRO = "Dark is the default. Light changes the sign-in screen, Owner settings, the call and alarm screens, and the Profile and nApps screens inside a profile on this phone. Other apps keep their own look.";
    static final String SWITCH = "Light mode";
    static final String NOTE = "The phone still starts on a black screen. The gate redraws when you change this, and Owner settings closes.";
    static final String FAILED = "Couldn't change that setting";
    static final String OWNER_ONLY = "Only the owner can change the look";
    static final String OWNER_ONLY_NOTE = "The sun and moon on the sign-in screen are hidden, so the look changes only here.";
}
