package com.nowhere.chooser;

/** Cases for GateScreenTimeout (NWP-20261106-18, Q073). Exits 1 on any failure. */
public class GateScreenTimeoutCases {
    private static int failures = 0;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    public static void main(String[] args) {
        check("GATE_MS is 30000", GateScreenTimeout.GATE_MS == 30000);
        check("30000 is left alone", !GateScreenTimeout.needsWrite(30000));
        check("60000 is rewritten", GateScreenTimeout.needsWrite(60000));
        check("15000 is rewritten", GateScreenTimeout.needsWrite(15000));
        check("a failed read (-1) is written", GateScreenTimeout.needsWrite(-1));
        if (failures > 0) System.exit(1);
        System.out.println("  cases ok");
    }
}
