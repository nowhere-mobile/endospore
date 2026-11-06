package com.nowhere.chooser;

/** NWP-20261106-14: the cases for WipeOnSave. */
public final class WipeOnSaveCases {
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

    private static void on(String v, boolean want) {
        eq("on(" + (v == null ? "null" : "\"" + v + "\"") + ")", want, guard(() -> WipeOnSave.on(v)));
    }

    public static void main(String[] args) {
        on("1", true);
        on(" 1 ", true);
        on(null, false);
        on("", false);
        on("0", false);
        on("yes", false);
        on("11", false);
        on("true", false);
        eq("recheckVerb(true)", "EVICT-RECHECK-SAVED", guard(() -> WipeOnSave.recheckVerb(true)));
        eq("recheckVerb(false)", "EVICT-RECHECK", guard(() -> WipeOnSave.recheckVerb(false)));
        eq("PREF", "wipesaved", WipeOnSave.PREF);
        if (failed > 0) {
            System.out.println(failed + " of " + n + " cases FAILED");
            System.exit(1);
        }
        System.out.println("PASS " + n + " cases");
    }
}
