package com.nowhere.chooser;

/** NWP-20261127-08: the outcome of every deferred (On-demand / Auto) row of one sign-in's installRoamedAppCode,
 *  sent to the daemon as one PLACEHOLDER-OUTCOMES line so login.log, which an issue report carries, tells a
 *  missing _meta from a refused install. raised = the archived placeholder was installed; noMeta = the restore
 *  staged no .appcode/&lt;pkg&gt;/_meta dir; refused = _meta present but installArchivedPlaceholder answered false;
 *  groupDep = a launcher-less group member (no placeholder by design); error = the row threw.
 *  line() is the wire order "raised noMeta refused groupDep error", decimal, each clamped to 0..99999 (the agent
 *  refuses more than five digits). Counts only: no package name, label or path. Pure, java.lang only, so
 *  test-placeholder-outcomes-java.sh compiles it alone. */
final class PlaceholderTally {
    int raised;
    int noMeta;
    int refused;
    int groupDep;
    int error;

    boolean any() {
        return raised > 0 || noMeta > 0 || refused > 0 || groupDep > 0 || error > 0;
    }

    String line() {
        return clamp(raised) + " " + clamp(noMeta) + " " + clamp(refused) + " " + clamp(groupDep) + " " + clamp(error);
    }

    static int clamp(int v) {
        return v < 0 ? 0 : v > 99999 ? 99999 : v;
    }
}
