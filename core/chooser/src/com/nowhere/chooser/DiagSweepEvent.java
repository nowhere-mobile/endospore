package com.nowhere.chooser;

/** NWP-20261126-12: the argument line of DIAG-EVENT for one Auto sweep, "sweep <apps> <ok> <fail> <ms>" (the agent's
 *  daySummaryEventRe, core/agent/day_summary.go). Numbers only: it names no package, profile or path. Pure (java.*
 *  only), so core/vendor-common/bin/test-diag-sweep-event-java.sh runs it under javac. */
final class DiagSweepEvent {
    /** 12 digits: daySummaryEventRe takes at most 12 per field. An int has at most 10, so only ms is clamped. */
    static final long MAX_MS = 999_999_999_999L;

    private DiagSweepEvent() {}

    /** The line without a newline, or null when any value is negative (the agent would answer ERR-ARGS). */
    static String arg(int apps, int ok, int fail, long ms) {
        if (apps < 0 || ok < 0 || fail < 0 || ms < 0) return null;
        return "sweep " + apps + " " + ok + " " + fail + " " + Math.min(ms, MAX_MS);
    }
}
