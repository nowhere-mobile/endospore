package com.nowhere.chooser;

/**
 * NWP-20261106-15: the erase picker's choices (Profile > Security > Auto-wipe when left locked), with "Right away,
 * once saved" first (Q138, docs/product-decisions.md, DECIDED 2026-10-20).
 *
 * That choice is carried as {@code wipe=1} PLUS {@code wipesaved=1} (WipeOnSave): a gate that does not know
 * {@code wipesaved} still reads {@code wipe=1} and erases after the 1-hour fallback bound, so the choice never
 * degrades to keeping the session. Pure java.lang so a javac suite can compile it off the build host.
 */
final class WipeChoice {
    private WipeChoice() {}

    /** The picker's labels, in order. */
    static final String[] LABELS = {
        "Right away, once saved", "After 1 hour", "After 6 hours", "After 12 hours", "After 1 day", "Only on power-off"
    };

    /** The wipe= hours each choice writes; 0 = keep until power-off. Choice 0 is the 1-hour fallback bound. */
    static final int[] HOURS = { 1, 1, 6, 12, 24, 0 };

    /** Whether each choice also writes wipesaved=1. */
    static final boolean[] SAVED = { true, false, false, false, false, false };

    /** After 12 hours: ChooserActivity's HARD_WIPE_MS, the gate's default when there is no wipe= pref. */
    private static final int DEFAULT = 3;

    /** The choice a profile's prefs show: wipesaved=1 is choice 0; otherwise the first choice from 1 whose hours equal
     *  wipe; a wipe that is unset, unparseable or matches no choice shows the gate's default. */
    static int selected(String wipe, String wipesaved) {
        if (WipeOnSave.on(wipesaved)) return 0;
        int h;
        try {
            h = Integer.parseInt(wipe == null ? "" : wipe.trim());
        } catch (NumberFormatException e) {
            return DEFAULT;
        }
        for (int i = 1; i < HOURS.length; i++) if (HOURS[i] == h) return i;
        return DEFAULT;
    }

    /** The wipe= value choice i writes. */
    static String wipeValue(int i) { return String.valueOf(HOURS[i]); }

    /** The wipesaved= value choice i writes: "1", or "" to remove the key. */
    static String savedValue(int i) { return SAVED[i] ? "1" : ""; }
}
