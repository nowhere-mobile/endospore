package com.nowhere.chooser;

/** NWP-20261011-01 (Chester, 2026-10-11): how long backups may wait while apps set up -- the profile's choice of the
 *  maximum time materialisation (a tapped app's download and install, or the Auto-install sweep) may hold the daemon's
 *  periodic backup back. Stored per profile in getFilesDir()/nowhere-seal-hold, which seals and roams with the
 *  profile; roamd surfaces it to the daemon at sign-in and SET-SEAL-HOLD applies a change at once (the daemon side is
 *  core/agent/seal_hold.go, whose four values these must match). Pure java.lang, so
 *  core/chooser/tests/seal-hold runs it under plain javac. */
final class SealHold {
    private SealHold() {}

    /** The stored values, in the order the picker shows them. */
    static final String[] VALUES = { "2", "10", "30", "run" };
    /** Absent, unreadable or unknown values all mean this. */
    static final String DEFAULT = "30";
    static final String FILE = "nowhere-seal-hold";

    /** The stored value if it is one of the four choices, else the default. */
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
            case "2": return "About 2 minutes";
            case "10": return "10 minutes";
            case "run": return "Until setup finishes";
            default: return "30 minutes";
        }
    }

    /** The choice's trade-off, in one line. */
    static String tradeoff(String v) {
        switch (normalize(v)) {
            case "2": return "Backups keep running during setup; a large app, or an Auto install, can take longer to set up";
            case "10": return "Apps set up faster; if the phone crashes during setup you can lose up to 10 more minutes of changes";
            case "run": return "Backups wait for all of setup, even a background Auto install that can take hours; a crash can lose everything since the last backup before it";
            default: return "Apps set up faster; if the phone crashes during setup you can lose up to 30 more minutes of changes";
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
     *  saved: the roaming copy was written. reply: the daemon's answer to SET-SEAL-HOLD, "" or null when none came.
     *  Every message is true in every case: OK means applied now; ERR means the daemon refused it (no live session,
     *  or it could not record it), so only the saved copy will carry it, at the next sign-in; no answer means it may
     *  or may not have landed, and the saved copy carries it at the next sign-in either way. */
    static String afterSave(boolean saved, String reply) {
        if (!saved) return SAVE_FAILED;
        if ("OK".equals(reply)) return null;
        if ("ERR".equals(reply)) return NEXT_SIGN_IN;
        return MAYBE_NOW;
    }
}
