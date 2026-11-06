package com.nowhere.chooser;

/** NWP-20261106-03: the cases for AutoLogoffGate. */
public final class AutoLogoffGateCases {
    private static int failed = 0;

    private static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + show(want) + " got " + show(got));
        }
    }

    private static String show(Object o) { return o == null ? "null" : "\"" + o + "\""; }

    private interface Call { Object run(); }

    /** An exception from the method under test is a failed case, never a pass. */
    private static Object guard(Call c) {
        try { return c.run(); } catch (Throwable t) { return "threw " + t; }
    }

    private static void h(String cls, boolean extra, boolean want) {
        eq("honoured(" + show(cls) + ", " + extra + ")", want, guard(() -> AutoLogoffGate.honoured(cls, extra)));
    }

    public static void main(String[] args) {
        eq("ALIAS", "com.nowhere.chooser.AutoLogoff", guard(() -> AutoLogoffGate.ALIAS));
        h(AutoLogoffGate.ALIAS, true, true);
        h("com.nowhere.chooser.ProfileActivity", true, false);
        h(AutoLogoffGate.ALIAS, false, false);
        h(null, true, false);
        h("", true, false);
        h("com.nowhere.chooser.AutoLogoffX", true, false);
        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases passed");
    }
}
