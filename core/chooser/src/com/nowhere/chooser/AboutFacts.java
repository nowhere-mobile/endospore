package com.nowhere.chooser;

import java.util.Locale;

/**
 * The words on the gate's "About" page (NWP-20261030-07; decision 2026-10-20, docs/product-decisions.md,
 * item 3), lifted out of ChooserActivity so javac can run them. The page REPORTS what the running software says
 * about itself and makes no privacy claim. An unknown, empty or missing value is "Not reported": a raw value is never
 * echoed as if it were a state. Pure: java.lang and java.util only.
 */
final class AboutFacts {
    private AboutFacts() {}

    static final String NOT_REPORTED = "Not reported";

    /** The name of the gate's Settings row and of the page it opens: one name for both (decision 2026-10-29,
     *  docs/product-decisions.md, fourth bullet, and its inference; NWP-20261117-42). */
    static final String TITLE = "About";

    static final String CANNOT_PROVE = "These values are reported by the software running on this phone. "
            + "Software that is not genuine can report them falsely, so this page cannot prove the phone runs a "
            + "genuine image.";

    private static String norm(String v) {
        return v == null ? "" : v.trim().toLowerCase(Locale.ROOT);
    }

    /** ro.boot.verifiedbootstate: green / yellow / orange in words; anything else is "Not reported". */
    static String bootState(String v) {
        switch (norm(v)) {
            case "green":
                return "Verified — checked at boot against the phone maker's key";
            case "yellow":
                return "Verified with a custom key — checked at boot against a key installed on this phone, "
                        + "not the phone maker's. A locked Nowhere phone boots this way.";
            case "orange":
                return "Not verified — the bootloader is unlocked, so the software was not checked at boot";
            default:
                return NOT_REPORTED;
        }
    }

    /** ro.boot.flash.locked: "1" is Locked, "0" is Unlocked; anything else is "Not reported". */
    static String bootloader(String v) {
        String t = v == null ? "" : v.trim();
        if (t.equals("1")) return "Locked";
        if (t.equals("0")) return "Unlocked";
        return NOT_REPORTED;
    }

    /** A plain property value, trimmed; "Not reported" when it is empty or missing. */
    static String orNotReported(String v) {
        String t = v == null ? "" : v.trim();
        return t.isEmpty() ? NOT_REPORTED : t;
    }
}
