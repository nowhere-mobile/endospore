package com.nowhere.chooser;

/** NWP-20261203-18: the progress notification's Pause and Stop. Runs HoldNotice and SweepJoin as they are, under plain
 *  javac. */
public final class HoldNoticeCases {
    private static int fails;

    private static void ok(boolean cond, String name) {
        if (cond) System.out.println("ok " + name);
        else { System.out.println("FAIL " + name); fails++; }
    }

    public static void main(String[] args) {
        // C1: the actions are offered only while a sweep runs and nothing holds it.
        for (SweepHold.State s : SweepHold.State.values()) {
            ok(!HoldNotice.offer(false, s), "C1 no sweep running, " + s + ": no actions");
        }
        ok(HoldNotice.offer(true, SweepHold.State.NONE), "C1 a sweep running, NONE: Pause and Stop");
        ok(!HoldNotice.offer(true, SweepHold.State.PAUSED), "C1 a sweep running, PAUSED: no actions");
        ok(!HoldNotice.offer(true, SweepHold.State.STOPPED), "C1 a sweep running, STOPPED: no actions");
        ok("pause".equals(HoldNotice.HOLD_PAUSE) && "stop".equals(HoldNotice.HOLD_STOP), "C1 the words are pause and stop");
        ok(!HoldNotice.HOLD_PAUSE.equals(HoldNotice.HOLD_STOP), "C1 the two words differ");

        // C2: SweepJoin.running() follows the walk, a rerun included.
        SweepJoin.reset();
        ok(!SweepJoin.running(), "C2 idle: not running");
        ok(SweepJoin.enter(0), "C2 the first start owns the walk");
        ok(SweepJoin.running(), "C2 after enter: running");
        ok(!SweepJoin.enter(SweepJoin.LANDING), "C2 a second start joins");
        ok(SweepJoin.running(), "C2 a join keeps it running");
        ok(SweepJoin.exit() >= 0, "C2 the pass ends with a rerun");
        ok(SweepJoin.running(), "C2 still running across the rerun exit");
        ok(SweepJoin.exit() == -1, "C2 the rerun ends the walk");
        ok(!SweepJoin.running(), "C2 after the last exit: not running");
        ok(SweepJoin.enter(0) && SweepJoin.running() && SweepJoin.exit() == -1 && !SweepJoin.running(),
                "C2 a later walk starts and ends the same way");

        if (fails > 0) { System.out.println(fails + " FAILED"); System.exit(1); }
        System.out.println("all HoldNotice cases passed");
    }
}
