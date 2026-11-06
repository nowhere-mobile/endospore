package com.nowhere.chooser;

/**
 * NWP-20261106-14: the gate half of "erase once saved" (Q138, docs/product-decisions.md, DECIDED 2026-10-20).
 *
 * A profile that chose to be wiped as soon as its state is saved carries {@code wipesaved=1} in its roamed
 * nowhere-prefs. The picker writes it WITH {@code wipe=1}, so an older gate that reads only {@code wipe=} still
 * erases, after the 1-hour hard-wipe fallback. A gate that reads it asks the daemon EVICT-RECHECK-SAVED at the cold
 * lock's re-check (core/agent/coldlock_evict.go, handleEvictRecheckSaved) instead of EVICT-RECHECK, so a clean lock
 * is wiped too once the last save landed.
 *
 * Anything but "1" keeps today's EVICT-RECHECK path: an unreadable value fails toward the behaviour already shipped.
 * Pure java.lang so a javac suite can compile it off the build host.
 */
final class WipeOnSave {
    private WipeOnSave() {}

    /** The key in nowhere-prefs. */
    static final String PREF = "wipesaved";

    /** True only for the value "1" (surrounding whitespace ignored); null, empty, "0" and anything else are false. */
    static boolean on(String v) {
        return v != null && "1".equals(v.trim());
    }

    /** The daemon verb the cold lock's re-check sends. */
    static String recheckVerb(boolean onSave) {
        return onSave ? "EVICT-RECHECK-SAVED" : "EVICT-RECHECK";
    }
}
