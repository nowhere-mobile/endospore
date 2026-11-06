package com.nowhere.chooser;

/** SessionLiveClear.observe / shouldClear: which checks count toward a clear of sessionLive. */
public final class SessionLiveClearCases {
    static int fails = 0;

    static void eq(String what, long got, long want) {
        if (got != want) { fails++; System.out.println("--- FAIL " + what + ": got " + got + " want " + want); }
    }

    static void is(String what, boolean got, boolean want) {
        if (got != want) { fails++; System.out.println("--- FAIL " + what + ": got " + got + " want " + want); }
    }

    public static void main(String[] a) {
        // C1: live, not busy, none unlocked twice: the second check clears, the first does not.
        int s = SessionLiveClear.observe(0, true, false, Boolean.FALSE);
        eq("(C1) streak after one FALSE", s, 1);
        is("(C1) no clear after one FALSE", SessionLiveClear.shouldClear(s), false);
        s = SessionLiveClear.observe(s, true, false, Boolean.FALSE);
        eq("(C1) streak after two FALSE", s, 2);
        is("(C1) clear after two FALSE", SessionLiveClear.shouldClear(s), true);

        // C2: one FALSE alone never clears.
        is("(C2) one FALSE", SessionLiveClear.shouldClear(SessionLiveClear.observe(0, true, false, Boolean.FALSE)), false);

        // C3: an unlocked user between two FALSEs starts the streak again.
        s = SessionLiveClear.observe(0, true, false, Boolean.FALSE);
        s = SessionLiveClear.observe(s, true, false, Boolean.TRUE);
        eq("(C3) TRUE resets", s, 0);
        s = SessionLiveClear.observe(s, true, false, Boolean.FALSE);
        eq("(C3) FALSE after TRUE", s, 1);
        is("(C3) no clear", SessionLiveClear.shouldClear(s), false);

        // C4: null (unsure) never counts and resets.
        eq("(C4) null from 0", SessionLiveClear.observe(0, true, false, null), 0);
        eq("(C4) null after one FALSE", SessionLiveClear.observe(1, true, false, null), 0);
        s = SessionLiveClear.observe(0, true, false, Boolean.FALSE);
        s = SessionLiveClear.observe(s, true, false, null);
        s = SessionLiveClear.observe(s, true, false, Boolean.FALSE);
        is("(C4) FALSE, null, FALSE does not clear", SessionLiveClear.shouldClear(s), false);

        // C5: busy never counts, whatever the answer.
        eq("(C5) busy FALSE from 1", SessionLiveClear.observe(1, true, true, Boolean.FALSE), 0);
        eq("(C5) busy FALSE from 0", SessionLiveClear.observe(0, true, true, Boolean.FALSE), 0);
        eq("(C5) busy null", SessionLiveClear.observe(1, true, true, null), 0);

        // C6: not live never counts.
        eq("(C6) not live FALSE from 1", SessionLiveClear.observe(1, false, false, Boolean.FALSE), 0);
        eq("(C6) not live FALSE from 0", SessionLiveClear.observe(0, false, false, Boolean.FALSE), 0);

        // C7: the threshold is two.
        is("(C7) shouldClear(0)", SessionLiveClear.shouldClear(0), false);
        is("(C7) shouldClear(1)", SessionLiveClear.shouldClear(1), false);
        is("(C7) shouldClear(2)", SessionLiveClear.shouldClear(2), true);
        is("(C7) shouldClear(3)", SessionLiveClear.shouldClear(3), true);

        // C8: the cadence is the parked tier's 15 s.
        eq("(C8) RECHECK_MS", SessionLiveClear.RECHECK_MS, 15000L);

        if (fails > 0) { System.out.println("--- FAIL " + fails + " case(s)"); System.exit(1); }
        System.out.println("ok  SessionLiveClear: all cases pass");
    }
}
