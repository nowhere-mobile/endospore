package com.nowhere.chooser;

import java.util.Arrays;

/** NWP-20261201-13: the Auto sweep's Pause and Stop. Runs SweepHold and LandingLine as they are, under plain javac; the
 *  first check needs a fresh JVM, which this class is. */
public final class SweepHoldCases {
    private static int fails;

    private static void ok(boolean cond, String name) {
        if (cond) System.out.println("ok " + name);
        else { System.out.println("FAIL " + name); fails++; }
    }

    private static void eq(Object got, Object want, String name) {
        boolean same = want == null ? got == null : want.equals(got);
        ok(same, name + (same ? "" : " (got " + got + ", want " + want + ")"));
    }

    /** RF-002's order, with the Resume on its own thread as it is on the device: the pass records its pause and broadcasts
     *  it, the Resume lands while the pass is still in SweepJoin, and the owner thread then runs the rerun. The steps are
     *  sweepAutoJoined's and sweepAuto's own; H8 and H10 pin that the real code takes them. */
    private static void resumeJoinsTheEndingPass() {
        SweepJoin.reset();
        long card = LandingLine.Sweep.begin(new String[] {"a", "b", "c"});
        ok(SweepJoin.enter(0), "J1 the first pass owns the sweep");
        LandingLine.Sweep.outcome(card, "a", true);
        SweepHold.pause(card);
        LandingLine.Sweep.pause(card);
        ok(LandingLine.Sweep.paused(card), "J1 the card shows paused before the pass ends");

        final boolean[] joined = new boolean[1];
        Thread resumeTap = new Thread(() -> {
            SweepHold.resume();
            joined[0] = !SweepJoin.enter(0);
        });
        resumeTap.start();
        try { resumeTap.join(); } catch (InterruptedException e) { throw new RuntimeException(e); }
        ok(joined[0], "J2 the Resume joins the ending pass");
        ok(!SweepHold.held(), "J2 the Resume ended the hold");

        eq(SweepJoin.exit(), 0, "J3 the ending pass owes one rerun");
        long resumed = SweepHold.takeResumed();
        eq(resumed, card, "J3 the rerun continues the paused card");
        LandingLine.Sweep.resume(resumed);
        ok(!LandingLine.Sweep.paused(card), "J4 the rerun takes the card out of paused");
        ok(!LandingLine.Sweep.stopped(card) && !LandingLine.Sweep.done(card), "J4 the card's controls run again");
        LandingLine.Sweep.outcome(resumed, "b", true);
        eq(Arrays.toString(LandingLine.Sweep.landed(card)), "[true, true, false]", "J5 the rerun updates the card's rows");
        LandingLine.Sweep.outcome(resumed, "c", true);
        LandingLine.Sweep.end(resumed);
        ok(LandingLine.Sweep.done(card), "J6 the rerun ends the card");
        eq(SweepJoin.exit(), -1, "J6 no pass is owed after the rerun");
    }

    /** The other order: the pass has left SweepJoin, so the Resume owns the walk. */
    private static void resumeAfterTheJoinEnded() {
        SweepJoin.reset();
        long card = LandingLine.Sweep.begin(new String[] {"a"});
        ok(SweepJoin.enter(0), "J7 the first pass owns the sweep");
        SweepHold.pause(card);
        LandingLine.Sweep.pause(card);
        eq(SweepJoin.exit(), -1, "J7 the pass ends with nothing joined");
        SweepHold.resume();
        ok(SweepJoin.enter(0), "J7 the Resume owns a new walk");
        eq(SweepHold.takeResumed(), card, "J7 its pass continues the paused card");
        eq(SweepJoin.exit(), -1, "J7 its pass ends the walk");
    }

    /** UnarchiveService's close of a pass, which H7 pins line for line. */
    private static void closePass(long card, boolean cut) {
        SweepHold.Close close = SweepHold.close(card, cut);
        if (close == SweepHold.Close.PAUSE) LandingLine.Sweep.pause(card);
        else if (close == SweepHold.Close.STOP) LandingLine.Sweep.stop(card);
        else if (close == SweepHold.Close.END) LandingLine.Sweep.end(card);
    }

    /** What the card does on the pass's completion broadcast: render's two buttons and sync's close. */
    private static void cardRuns(long card, String id) {
        ok(!LandingLine.Sweep.done(card), id + " the completion broadcast schedules no close");
        ok(!LandingLine.Sweep.paused(card), id + " the card does not read paused");
        ok(!LandingLine.Sweep.done(card), id + " Pause stays enabled");
        ok(!LandingLine.Sweep.done(card) && !LandingLine.Sweep.paused(card), id + " Stop stays enabled");
    }

    private static void freshHold() {
        SweepHold.clear();
        SweepHold.takeResumed();
        SweepJoin.reset();
    }

    /** RF-003: "Resume installing apps" lands after the pass cut the sweep and before the pass closes the card. */
    private static void profileResumeBeforeThePassCloses() {
        freshHold();
        long card = LandingLine.Sweep.begin(new String[] {"a", "b", "c"});
        ok(SweepJoin.enter(0), "P1 the first pass owns the sweep");
        LandingLine.Sweep.outcome(card, "a", true);
        SweepHold.pause(card);
        SweepHold.clear();
        ok(!SweepJoin.enter(SweepJoin.BY_HAND), "P1 the by-hand start joins the ending pass");
        eq(SweepHold.close(card, true), SweepHold.Close.CONTINUE, "P1 a card the next pass continues stays open");
        closePass(card, true);
        cardRuns(card, "P1");
        eq(SweepJoin.exit(), SweepJoin.BY_HAND, "P2 the ending pass hands the by-hand rerun back");
        eq(SweepHold.takeResumed(), card, "P2 the rerun continues the card");
        LandingLine.Sweep.resume(card);
        cardRuns(card, "P2");
        LandingLine.Sweep.outcome(card, "b", true);
        LandingLine.Sweep.outcome(card, "c", true);
        closePass(card, false);
        ok(LandingLine.Sweep.done(card), "P2 the rerun ends the card when it finishes");
        eq(SweepJoin.exit(), -1, "P2 the rerun ends the walk");

        // The by-hand start's thread can reach the join only after the ending pass has left it.
        freshHold();
        long late = LandingLine.Sweep.begin(new String[] {"a", "b"});
        ok(SweepJoin.enter(0), "P3 the first pass owns the sweep");
        SweepHold.pause(late);
        SweepHold.clear();
        closePass(late, true);
        cardRuns(late, "P3");
        eq(SweepJoin.exit(), -1, "P3 the pass ends with nothing joined");
        ok(SweepJoin.enter(SweepJoin.BY_HAND), "P3 the by-hand start owns a new walk");
        eq(SweepHold.takeResumed(), late, "P3 its pass continues the card");
        eq(SweepJoin.exit(), -1, "P3 its pass ends the walk");

        // A rerun that stops on a busy remembered tap leaves the card paused, as UnarchiveService's H13 branch does.
        freshHold();
        long busy = LandingLine.Sweep.begin(new String[] {"a"});
        SweepHold.pause(busy);
        SweepHold.clear();
        closePass(busy, true);
        long waiting = SweepHold.takeResumed();
        SweepHold.pause(waiting);
        LandingLine.Sweep.pause(waiting);
        ok(LandingLine.Sweep.paused(busy), "P4 a card the rerun could not continue offers Resume");
        ok(!LandingLine.Sweep.done(busy), "P4 that card stays open");

        // Pause pressed again in the window: the pass reads the new pause and the card pauses.
        freshHold();
        long again = LandingLine.Sweep.begin(new String[] {"a"});
        SweepHold.pause(again);
        SweepHold.clear();
        SweepHold.pause(again);
        eq(SweepHold.close(again, true), SweepHold.Close.PAUSE, "P5 a second Pause in the window pauses the card");
        freshHold();
    }

    /** The close decision itself. */
    private static void passCloseDecision() {
        freshHold();
        SweepHold.pause(21L);
        eq(SweepHold.close(21L, false), SweepHold.Close.END, "C1 a pass that finished every app ends while paused");
        eq(SweepHold.close(21L, true), SweepHold.Close.PAUSE, "C2 a cut pass of a paused sweep pauses");
        SweepHold.stop();
        eq(SweepHold.close(21L, false), SweepHold.Close.END, "C1 a pass that finished every app ends while stopped");
        eq(SweepHold.close(21L, true), SweepHold.Close.STOP, "C2 a cut pass of a stopped sweep stops");
        freshHold();
        eq(SweepHold.close(21L, true), SweepHold.Close.END, "C3 a cut pass with no hold and no successor ends");
        eq(SweepHold.close(0L, true), SweepHold.Close.END, "C4 a pass with no card ends");
        SweepHold.pause(22L);
        SweepHold.clear();
        eq(SweepHold.close(23L, true), SweepHold.Close.END, "C4 another card's waiting resume does not keep this card");
        eq(SweepHold.close(22L, true), SweepHold.Close.CONTINUE, "C5 the waiting card continues");
        eq(SweepHold.close(22L, false), SweepHold.Close.END, "C5 a pass that cut nothing still ends");
        freshHold();
    }

    public static void main(String[] a) {
        // ---- SweepHold ----
        eq(SweepHold.state(), SweepHold.State.NONE, "T1 a fresh JVM is NONE");
        ok(!SweepHold.held(), "T1 a fresh JVM is not held");
        eq(SweepHold.resume(), 0L, "T1 resume with nothing held returns 0");

        SweepHold.pause(7L);
        eq(SweepHold.state(), SweepHold.State.PAUSED, "T2 pause sets PAUSED");
        ok(SweepHold.held(), "T2 a pause is held");
        eq(SweepHold.word(), "paused", "T2 the word is paused");
        eq(SweepHold.resume(), 7L, "T2 pause then resume returns the card id");
        eq(SweepHold.state(), SweepHold.State.NONE, "T2 resume clears PAUSED");
        ok(!SweepHold.held(), "T2 after a resume nothing is held");
        eq(SweepHold.resume(), 0L, "T2 a second resume returns 0");

        SweepHold.stop();
        eq(SweepHold.state(), SweepHold.State.STOPPED, "T3 stop sets STOPPED");
        eq(SweepHold.word(), "stopped", "T3 the word is stopped");
        eq(SweepHold.resume(), 0L, "T3 resume leaves STOPPED and returns 0");
        eq(SweepHold.state(), SweepHold.State.STOPPED, "T3 resume leaves STOPPED");
        SweepHold.pause(9L);
        eq(SweepHold.state(), SweepHold.State.STOPPED, "T3 pause from STOPPED changes nothing");
        eq(SweepHold.resume(), 0L, "T3 that pause stored no card");
        SweepHold.clear();
        eq(SweepHold.state(), SweepHold.State.NONE, "T4 clear resets STOPPED");
        eq(SweepHold.word(), "none", "T4 the word is none");

        SweepHold.pause(3L);
        SweepHold.stop();
        eq(SweepHold.state(), SweepHold.State.STOPPED, "T5 stop from PAUSED is STOPPED");
        eq(SweepHold.resume(), 0L, "T5 stop from PAUSED drops the card id");
        SweepHold.clear();
        SweepHold.pause(4L);
        SweepHold.pause(5L);
        eq(SweepHold.resume(), 5L, "T5 a pause from PAUSED takes the new card id");
        SweepHold.pause(6L);
        SweepHold.clear();
        eq(SweepHold.state(), SweepHold.State.NONE, "T5 clear resets PAUSED");
        eq(SweepHold.resume(), 0L, "T5 clear drops the card id");
        SweepHold.takeResumed();

        // ---- the card a resume hands to the next pass ----
        eq(SweepHold.takeResumed(), 0L, "R1 nothing resumed, nothing to take");
        SweepHold.pause(11L);
        eq(SweepHold.takeResumed(), 0L, "R1 a pause alone hands over nothing");
        SweepHold.resume();
        eq(SweepHold.takeResumed(), 11L, "R1 resume keeps the card for the next pass");
        eq(SweepHold.takeResumed(), 0L, "R1 only one pass takes the card");
        SweepHold.pause(12L);
        SweepHold.resume();
        SweepHold.resume();
        eq(SweepHold.takeResumed(), 12L, "R2 a second Resume tap does not lose the card");
        SweepHold.pause(13L);
        SweepHold.clear();
        eq(SweepHold.takeResumed(), 13L, "R3 a by-hand start continues a paused card");
        SweepHold.stop();
        SweepHold.clear();
        eq(SweepHold.takeResumed(), 0L, "R3 a by-hand start after a stop continues no card");
        SweepHold.clear();
        eq(SweepHold.takeResumed(), 0L, "R3 a by-hand start with nothing held continues no card");
        SweepHold.pause(14L);
        SweepHold.resume();
        SweepHold.clear();
        eq(SweepHold.takeResumed(), 14L, "R3 a by-hand start does not lose a Resume waiting for its pass");

        resumeJoinsTheEndingPass();
        profileResumeBeforeThePassCloses();
        passCloseDecision();
        resumeAfterTheJoinEnded();

        // ---- LandingLine.Sweep ----
        long s = LandingLine.Sweep.begin(new String[] {"a", "b"});
        ok(!LandingLine.Sweep.paused(s) && !LandingLine.Sweep.stopped(s), "S1 a new card is neither paused nor stopped");
        ok(!LandingLine.Sweep.done(s), "S1 a new card is not done");
        LandingLine.Sweep.pause(s);
        ok(LandingLine.Sweep.paused(s), "S2 pause records paused");
        ok(!LandingLine.Sweep.stopped(s), "S2 pause is not stopped");
        ok(!LandingLine.Sweep.done(s), "S2 done is false while paused");
        LandingLine.Sweep.resume(s);
        ok(!LandingLine.Sweep.paused(s), "S3 resume clears paused");
        ok(!LandingLine.Sweep.done(s), "S3 a resumed card is not done");
        LandingLine.Sweep.stop(s);
        ok(LandingLine.Sweep.stopped(s), "S4 stop records stopped");
        ok(!LandingLine.Sweep.paused(s), "S4 stop is not paused");
        ok(LandingLine.Sweep.done(s), "S4 done is true after stop");

        LandingLine.Sweep.pause(s);
        ok(!LandingLine.Sweep.stopped(s), "S5 pause after stop clears stopped");
        ok(!LandingLine.Sweep.done(s), "S5 pause after stop is not done");
        LandingLine.Sweep.end(s);
        ok(LandingLine.Sweep.done(s), "S5 end after pause is done");

        long t = LandingLine.Sweep.begin(new String[] {"a"});
        ok(t != s, "S6 begin gives a new id");
        ok(!LandingLine.Sweep.paused(t) && !LandingLine.Sweep.stopped(t) && !LandingLine.Sweep.done(t), "S6 begin resets paused, stopped and done");
        LandingLine.Sweep.pause(t);
        long u = LandingLine.Sweep.begin(new String[] {"a"});
        ok(!LandingLine.Sweep.paused(u), "S6 begin after a pause resets paused");
        LandingLine.Sweep.stop(u);
        long v = LandingLine.Sweep.begin(new String[] {"a"});
        ok(!LandingLine.Sweep.stopped(v), "S6 begin after a stop resets stopped");

        LandingLine.Sweep.pause(u);
        ok(!LandingLine.Sweep.paused(v), "S7 a stale id's pause changes nothing");
        LandingLine.Sweep.stop(u);
        ok(!LandingLine.Sweep.stopped(v) && !LandingLine.Sweep.done(v), "S7 a stale id's stop changes nothing");
        ok(!LandingLine.Sweep.paused(u) && !LandingLine.Sweep.stopped(u), "S7 a stale id reads neither paused nor stopped");
        LandingLine.Sweep.pause(0L);
        ok(!LandingLine.Sweep.paused(v) && !LandingLine.Sweep.paused(0L), "S7 id 0 changes nothing");
        LandingLine.Sweep.pause(v);
        LandingLine.Sweep.resume(u);
        ok(LandingLine.Sweep.paused(v), "S7 a stale id's resume changes nothing");
        LandingLine.Sweep.resume(0L);
        ok(LandingLine.Sweep.paused(v), "S7 id 0's resume changes nothing");

        long r = LandingLine.Sweep.begin(new String[] {"a", "b", "c"});
        LandingLine.Sweep.outcome(r, "a", false);
        LandingLine.Sweep.outcome(r, "b", true);
        LandingLine.Sweep.pause(r);
        LandingLine.Sweep.resume(r);
        LandingLine.Sweep.outcome(r, "a", true);
        LandingLine.Sweep.outcome(r, "c", true);
        LandingLine.Sweep.end(r);
        eq(Arrays.toString(LandingLine.Sweep.landed(r)), "[true, true, true]", "S8 a resume lands a retry of an app that failed before the pause");
        long f = LandingLine.Sweep.begin(new String[] {"a", "b"});
        LandingLine.Sweep.outcome(f, "a", true);
        LandingLine.Sweep.pause(f);
        LandingLine.Sweep.resume(f);
        LandingLine.Sweep.outcome(f, "a", false);
        LandingLine.Sweep.outcome(f, "b", false);
        eq(Arrays.toString(LandingLine.Sweep.landed(f)), "[true, false]", "S9 a resume keeps a landed app and a retry can fail again");

        // ---- the words ----
        eq(LandingLine.PAUSE, "Pause", "W1 the Pause word");
        eq(LandingLine.STOP, "Stop", "W1 the Stop word");
        eq(LandingLine.RESUME, "Resume", "W1 the Resume word");
        eq(LandingLine.RESUME_ROW, "Resume installing apps", "W1 the Your apps row");
        eq(LandingLine.heldLine(true, false, 1, 5), "Paused. The rest wait until you resume.", "W2 a paused card's line");
        eq(LandingLine.heldLine(false, true, 1, 5), "Stopped. The rest install when you tap them.", "W2 a stopped card's line");
        eq(LandingLine.heldLine(false, false, 1, 5), null, "W2 a running card has no held line");
        eq(LandingLine.heldLine(true, false, 5, 5), null, "W3 a paused card with every app landed has no held line");
        eq(LandingLine.heldLine(false, true, 5, 5), null, "W3 a stopped card with every app landed has no held line");
        eq(LandingLine.headline(5, 5), "All 5 apps are back", "W3 only every app landed says All");
        ok(!LandingLine.heldLine(true, false, 4, 5).contains("All"), "W3 a paused card with an app left does not say All");
        ok(!LandingLine.heldLine(false, true, 4, 5).contains("All"), "W3 a stopped card with an app left does not say All");

        System.out.println(fails == 0 ? "all cases passed" : fails + " case(s) failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
