package com.nowhere.chooser;

/** NWP-20261106-03, NWP-20261208-02: the cases for AutoLogoffGate. */
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

    /** NWP-20261208-02: the live-instance registry. Every item is held in a local until its check, so GC cannot
     *  clear it early. */
    private static void live() {
        AutoLogoffGate.Live<String> empty = new AutoLogoffGate.Live<>();
        eq("L1 any on an empty Live", false, guard(() -> empty.any(s -> true)));

        AutoLogoffGate.Live<String> l = new AutoLogoffGate.Live<>();
        String busy = new String("busy");
        l.add(busy);
        eq("L2 any after add of a busy item", true, guard(() -> l.any(s -> s.equals("busy"))));
        l.remove(busy);
        eq("L3 any after remove", false, guard(() -> l.any(s -> s.equals("busy"))));

        AutoLogoffGate.Live<String> id = new AutoLogoffGate.Live<>();
        String a = new String("x");
        String b = new String("x");
        id.add(a);
        id.add(b);
        id.remove(a);
        eq("L4 remove is by identity (an equal-but-distinct item stays)", true, guard(() -> id.any(s -> true)));
        eq("L4 control: b is still held", "x", b);

        AutoLogoffGate.Live<String> idle = new AutoLogoffGate.Live<>();
        String i = new String("idle");
        idle.add(i);
        eq("L5 any when the only live item is not busy", false, guard(() -> idle.any(s -> s.equals("busy"))));
        eq("L5 control: the idle item is still held", "idle", i);
    }

    public static void main(String[] args) {
        eq("ALIAS", "com.nowhere.chooser.AutoLogoff", guard(() -> AutoLogoffGate.ALIAS));
        h(AutoLogoffGate.ALIAS, true, true);
        h("com.nowhere.chooser.ProfileActivity", true, false);
        h(AutoLogoffGate.ALIAS, false, false);
        h(null, true, false);
        h("", true, false);
        h("com.nowhere.chooser.AutoLogoffX", true, false);
        // NWP-20261208-02: the L4 start decision.
        eq("G1 shouldStart(4,5,false)", false, guard(() -> AutoLogoffGate.shouldStart(4, 5, false)));
        eq("G2 shouldStart(5,5,false)", true, guard(() -> AutoLogoffGate.shouldStart(5, 5, false)));
        eq("G3 shouldStart(6,5,false)", true, guard(() -> AutoLogoffGate.shouldStart(6, 5, false)));
        eq("G4 shouldStart(5,5,true)", false, guard(() -> AutoLogoffGate.shouldStart(5, 5, true)));
        live();
        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases passed");
    }
}
