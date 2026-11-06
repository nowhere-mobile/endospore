package com.nowhere.chooser;

/** Cases for SessionScreenTimeout (NWP-20261113-13, Q073). Exits 1 on any failure. */
public class SessionScreenTimeoutCases {
    private static int failures = 0;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    public static void main(String[] args) {
        check("NEW_SESSION_MS is 60000", SessionScreenTimeout.NEW_SESSION_MS == 60000);
        check("60000 is left alone", !SessionScreenTimeout.needsWrite(60000));
        check("30000 (the gate's) is rewritten", SessionScreenTimeout.needsWrite(30000));
        check("a failed read (-1) is written", SessionScreenTimeout.needsWrite(-1));
        check("0 is rewritten", SessionScreenTimeout.needsWrite(0));
        check("600000 is rewritten", SessionScreenTimeout.needsWrite(600000));
        if (failures > 0) System.exit(1);
        System.out.println("  cases ok");
    }
}
