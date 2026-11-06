package com.nowhere.chooser;

/**
 * NWP-20261109-07 (Q183, docs/product-decisions.md, DECIDED 2026-10-20): when the gate's cold-lock eviction re-check
 * stops asking. The daemon answers {@code RETRY busy} when an op it abandoned still holds the RW lane, and that can
 * last minutes -- the five tries were sized for vold's retries, not for that, so a busy answer is NOT counted. The
 * re-check keeps asking (each ask re-runs the daemon's evictcheck, which re-runs the cache drop once the lane frees)
 * until the profile's own hard-wipe time has passed since the stop, after which the hard wipe decides. A "Never"
 * profile (wipe= 0) still stops after the 12 h default; its session simply stays locked. Pure java.lang.
 */
final class EvictRetry {
    private EvictRetry() {}

    /** Non-answers other than "RETRY busy" (empty, "RETRY no-verdict", anything unknown) before the re-check gives up. */
    static final int NO_VERDICT_TRIES = 5;

    /** True when the daemon's evictcheck worker op answered busy (coldlock_evict.go evictDecision). */
    static boolean busy(String reply) {
        return reply != null && reply.startsWith("RETRY busy");
    }

    /** The profile's hard-wipe time; "Never" (wipe= 0 or less) falls back to the 12 h default. */
    static long bound(long wipeMs, long hardWipeMs) {
        return wipeMs > 0 ? wipeMs : hardWipeMs;
    }

    /** Stop asking: enough non-busy non-answers, or the profile's hard-wipe time has passed since the stop. */
    static boolean giveUp(int noVerdict, long sinceStopMs, long boundMs) {
        return noVerdict >= NO_VERDICT_TRIES || sinceStopMs >= boundMs;
    }
}
