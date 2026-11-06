package com.nowhere.chooser;

/** NWP-20261026-20: the cases for RemoveRetry (made-up replies only). */
public final class RemoveRetryCases {
    private static int failed = 0;
    private static int n = 0;
    private static final int G = RemoveRetry.GRACE;

    private static void eq(String what, Object want, Object got) {
        n++;
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

    private static void next(int tries, boolean ext, String reply, String want) {
        eq("next(" + tries + ", " + ext + ", " + show(reply) + ")", want, guard(() -> RemoveRetry.next(tries, ext, reply)));
    }

    private static void words(String reply, String want) {
        eq("countWords(" + show(reply) + ")", want, guard(() -> RemoveRetry.countWords(reply)));
    }

    public static void main(String[] args) {
        final String U = "an unknown number of";
        eq("GRACE", 16, RemoveRetry.GRACE);

        next(0, false, "OK 0", "RETRY");
        next(1, false, null, "RETRY");
        next(G - 1, false, "OK 0", "RETRY");
        next(G - 1, false, "OK 3", "RETRY");
        next(G, true, null, "RETRY");
        next(2 * G - 1, true, "OK 0", "RETRY");

        next(G, false, "OK 0", "REBOOT");
        next(G, false, " OK 0 \n", "REBOOT");
        next(G, false, "OK 3", "EXTEND");
        next(G, false, " OK 3 \n", "EXTEND");
        next(G, false, "OK -1", "EXTEND");
        next(G, false, "OK x", "EXTEND");
        next(G, false, "OK 00", "EXTEND");
        next(G, false, "", "EXTEND");
        next(G, false, null, "EXTEND");
        next(G, false, "ERR", "EXTEND");
        next(G, false, "DENIED", "EXTEND");
        next(G, false, "garbage", "EXTEND");
        next(G + 1, false, "OK 3", "EXTEND");

        for (String r : new String[] {"OK 3", "", null, "ERR", "OK 0"}) next(2 * G, true, r, "REBOOT");
        next(2 * G + 5, true, "OK 3", "REBOOT");

        // The whole walk, as doRemove's Runnable takes it: one EXTEND, then REBOOT at 2 * GRACE, none before.
        int extends_ = 0, reboot = -1;
        boolean ext = false;
        for (int t = 1; t <= 4 * G && reboot < 0; t++) {
            String d = RemoveRetry.next(t, ext, null);
            if ("RETRY".equals(d)) continue;
            d = RemoveRetry.next(t, ext, "OK 3");
            if ("EXTEND".equals(d)) { extends_++; ext = true; continue; }
            if ("REBOOT".equals(d)) reboot = t;
        }
        eq("walk: extensions", 1, extends_);
        eq("walk: reboot at", 2 * G, reboot);

        words("OK 0", "0");
        words("OK 3", "3");
        words(" OK 3 \n", "3");
        words("OK 007", "7");
        for (String r : new String[] {"OK -1", "OK x", "OK 3 4", "OK ", "", null, "ERR", "DENIED", "OK 9999999999"}) words(r, U);

        System.out.println(failed == 0 ? "ok " + n + " cases" : failed + " of " + n + " cases FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
