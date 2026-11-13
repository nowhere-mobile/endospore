package com.nowhere.chooser;

/**
 * NWP-20261117-25: the gate's sun/moon (docs/product-decisions.md, 2026-10-29, "three answers — the gate clears its
 * sign-in fields when the screen turns off ...", second bullet). A glyph in the gate's top-right corner, left of the
 * help "?", shows a sun while the gate is dark and a moon while it is light, as the storefront's toggle does; a tap
 * switches the one device-wide look with no owner passphrase. The decision's two inferences, built as written: the
 * glyph shows the look a tap switches to, and ~~Owner settings › Appearance stays as a second way to set it~~
 * (superseded 2026-11-06, "Owner settings loses Appearance ...", NWP-20261130-13: this is the only light/dark control).
 *
 * NWP-20261124-15 (docs/product-decisions.md, 2026-11-02, "twenty-four answers to the open-decisions list ...", #11):
 * the owner can make the look owner-only (Owner settings › Appearance, OWNER_ONLY_KEY). While it is, the glyph is
 * hidden, because the gate never offers a control that refuses, and toggleGateLook writes nothing.
 *
 * The look is the same for everyone at the gate and tells nothing about any profile. Pure java.lang plus GatePalette,
 * so the cases compile both as-is (core/chooser/tests/gate-look-glyph).
 */
final class GateLookGlyph {
    private GateLookGlyph() {}

    static final String TO_LIGHT = "Switch to light mode";
    static final String TO_DARK = "Switch to dark mode";

    /** NWP-20261124-15: the gate's "nowhere_gate" prefs boolean the owner sets in Owner settings › Appearance.
     *  Absent is false: anyone at the gate can tap the sun/moon, as before. Device-wide, like GatePalette.KEY. */
    static final String OWNER_ONLY_KEY = "gate_look_owner_only";

    /** Whether the gate shows the sun/moon: not while the owner has made the look owner-only. */
    static boolean shown(boolean ownerOnly) {
        return !ownerOnly;
    }

    /** A sun while the gate is dark: a fresh phone, with no gate_look, is dark and shows the sun. */
    static boolean sun(GatePalette p) {
        return p != GatePalette.LIGHT;
    }

    /** The value a tap stores: the other look. Anything that does not read LIGHT goes to light. */
    static String next(String stored) {
        return GatePalette.valueFor(GatePalette.forLook(stored) != GatePalette.LIGHT);
    }

    /** What a tap does, for a screen reader. */
    static String description(GatePalette p) {
        return sun(p) ? TO_LIGHT : TO_DARK;
    }
}
