package com.nowhere.chooser;

/** NWP-20261109-07: the cases for EvictRetry. */
public final class EvictRetryCases {
    private static int failed = 0;
    private static int n = 0;

    private static void eq(String what, Object want, Object got) {
        n++;
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + want + " got " + got);
        }
    }

    private interface Call { Object run(); }

    /** An exception from the method under test is a failed case, never a pass. */
    private static Object guard(Call c) {
        try { return c.run(); } catch (Throwable t) { return "threw " + t; }
    }

    private static void busy(String r, boolean want) {
        eq("busy(" + (r == null ? "null" : "\"" + r + "\"") + ")", want, guard(() -> EvictRetry.busy(r)));
    }

    private static void giveUp(int tries, long since, long bound, boolean want) {
        eq("giveUp(" + tries + ", " + since + ", " + bound + ")", want,
                guard(() -> EvictRetry.giveUp(tries, since, bound)));
    }

    private static void bound(long wipe, long hard, long want) {
        eq("bound(" + wipe + ", " + hard + ")", want, guard(() -> EvictRetry.bound(wipe, hard)));
    }

    public static void main(String[] args) {
        // E1
        busy("RETRY busy", true);
        busy("RETRY busy lane", true);
        busy("RETRY no-verdict", false);
        busy("", false);
        busy(null, false);
        busy("KEEP UNSAVED x", false);
        // E2
        giveUp(4, 0, 1000, false);
        giveUp(5, 0, 1000, true);
        giveUp(0, 1000, 1000, true);
        giveUp(0, 999, 1000, false);
        // E3
        bound(0, 43200000L, 43200000L);
        bound(-1, 43200000L, 43200000L);
        bound(3600000L, 43200000L, 3600000L);
        eq("NO_VERDICT_TRIES", 5, EvictRetry.NO_VERDICT_TRIES);
        if (failed > 0) {
            System.out.println(failed + " of " + n + " cases FAILED");
            System.exit(1);
        }
        System.out.println("all " + n + " cases passed");
    }
}
