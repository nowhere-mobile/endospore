package com.nowhere.chooser;

/** NWP-20261201-05 (Chester, 2026-11-07, docs/product-decisions.md): when this profile's periodic saves run -- Always,
 *  Only on Wi-Fi or Off. Only the periodic save reads it; a sign-out and Back up now save in every mode. Stored per
 *  profile in getFilesDir()/nowhere-save-mode, which seals and roams with the profile; SET-SAVE-MODE applies a change at
 *  once and GET-SAVE-MODE reads the live session's value. Pure java.lang, so core/chooser/tests/save-mode runs it under
 *  plain javac. */
final class SaveMode {
    private SaveMode() {}

    /** The stored values, in the order the picker shows them. */
    static final String[] VALUES = { "always", "wifi", "off" };
    /** Absent, unreadable or unknown values all mean this. */
    static final String DEFAULT = "always";
    static final String FILE = "nowhere-save-mode";

    /** The stored value if it is one of the three choices, else the default. */
    static String normalize(String v) {
        if (v != null) {
            v = v.trim();
            for (String c : VALUES) if (c.equals(v)) return v;
        }
        return DEFAULT;
    }

    /** The choice's name, for the picker and the row's chip. */
    static String label(String v) {
        switch (normalize(v)) {
            case "wifi": return "Only on Wi-Fi";
            case "off": return "Off";
            default: return "Always";
        }
    }

    /** The choice's trade-off, in one line. A lock is not named as a save: a cold lock never saves, in any mode
     *  (docs/product-decisions.md, 2026-11-09, #1). */
    static String tradeoff(String v) {
        switch (normalize(v)) {
            case "wifi": return "Saves on Wi-Fi or another unmetered network. On mobile data only a sign-out or Back up now saves";
            case "off": return "Saves only when you sign out or tap Back up now; if the phone crashes or powers off, changes since then are lost";
            default: return "Saves your changes every few minutes on any connection";
        }
    }

    /** The picker's item text: the name over its trade-off. */
    static String item(String v) {
        return label(v) + "\n" + tradeoff(v);
    }

    static final String SAVE_FAILED = "Couldn't save this choice. Try again.";
    static final String NEXT_SIGN_IN = "Saved. It applies from your next sign-in.";
    static final String MAYBE_NOW = "Saved. If it doesn't apply now, it will from your next sign-in.";

    /** What to tell the user after a choice, or null for nothing (it applies now and the chip already says so).
     *  saved: the roaming copy was written. reply: the daemon's answer to SET-SAVE-MODE, "" or null when none came.
     *  OK means applied now; ERR means the daemon did not take it, so only the saved copy will carry it, at the next
     *  sign-in; any other reply may or may not have landed, and the saved copy carries it either way. */
    static String afterSave(boolean saved, String reply) {
        if (!saved) return SAVE_FAILED;
        if ("OK".equals(reply)) return null;
        if ("ERR".equals(reply)) return NEXT_SIGN_IN;
        return MAYBE_NOW;
    }

    static final String WAITS_FOR_WIFI = "You're on mobile data. This profile saves on Wi-Fi only, so your recent changes will be saved when you're on Wi-Fi.";
    static final String NOT_SAVED_YET = "Your recent changes aren't saved to your store yet. Tap Back up now to save them.";

    /** The back-online prompt's text. mode: the daemon's GET-SAVE-MODE reply. unmetered: the active network is unmetered.
     *  Only a Wi-Fi-only profile off an unmetered network is told that its saves wait. */
    static String backNowBody(String mode, boolean unmetered) {
        return "wifi".equals(normalize(mode)) && !unmetered ? WAITS_FOR_WIFI : NOT_SAVED_YET;
    }
}
