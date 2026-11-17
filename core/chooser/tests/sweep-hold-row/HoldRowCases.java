package com.nowhere.chooser;

/** NWP-20261203-23: the cases of test-sweep-hold-row-java.sh. HoldRow decides what Your apps' install row offers, and
 *  SweepJoin.running() is what it reads to know a sweep runs. Each case prints `ok <id>` or `FAIL <id>`. */
public class HoldRowCases {
    private static int fails = 0;

    private static void check(String id, boolean ok, String what) {
        System.out.println((ok ? "ok " : "FAIL ") + id + " " + what);
        if (!ok) fails++;
    }

    public static void main(String[] a) {
        check("K1", HoldRow.mode(true, SweepHold.State.NONE) == HoldRow.RUNNING, "a running sweep with no hold is RUNNING");
        check("K2", HoldRow.mode(false, SweepHold.State.NONE) == HoldRow.INSTALL, "no sweep and no hold is INSTALL");
        check("K3", HoldRow.mode(true, SweepHold.State.PAUSED) == HoldRow.PAUSED, "a pause while the sweep ends is PAUSED");
        check("K4", HoldRow.mode(false, SweepHold.State.PAUSED) == HoldRow.PAUSED, "a pause after the sweep ended is PAUSED");
        check("K5", HoldRow.mode(true, SweepHold.State.STOPPED) == HoldRow.INSTALL, "a stop while the sweep ends is INSTALL");
        check("K6", HoldRow.mode(false, SweepHold.State.STOPPED) == HoldRow.INSTALL, "a stop after the sweep ended is INSTALL");

        check("K7", "Installing apps".equals(HoldRow.label(HoldRow.RUNNING))
                && "Installing apps".equals(LandingLine.RUNNING_ROW), "RUNNING reads \"Installing apps\" (RUNNING_ROW)");
        check("K8", "Resume installing apps".equals(HoldRow.label(HoldRow.PAUSED)), "PAUSED reads \"Resume installing apps\"");
        check("K9", "Install pending apps now".equals(HoldRow.label(HoldRow.INSTALL)), "INSTALL reads \"Install pending apps now\"");

        SweepJoin.reset();
        check("K10", !SweepJoin.running(), "idle: running() is false");
        boolean owns = SweepJoin.enter(0);
        check("K11", owns && SweepJoin.running(), "after the first enter: running() is true");
        boolean joined = !SweepJoin.enter(SweepJoin.BY_HAND);
        check("K12", joined && SweepJoin.running(), "a start that joins: running() stays true");
        int next = SweepJoin.exit();
        check("K13", next >= 0 && SweepJoin.running(), "an exit that hands back a rerun: running() stays true");
        next = SweepJoin.exit();
        check("K14", next < 0 && !SweepJoin.running(), "the last exit: running() is false");
        SweepJoin.reset();

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
