package com.nowhere.chooser;

/** Cases for RerunReapRule (NWP-20261128-04). Exit 0 when all pass, 1 otherwise. */
public class RerunReapRuleCases {
    static int fails = 0;

    static void eq(String what, long want, long got) {
        if (want == got) { System.out.println("  ok    " + what); return; }
        fails++;
        System.out.println("  FAIL  " + what + ": want " + want + ", got " + got);
    }

    static void eqs(String what, String want, String got) {
        if (want.equals(got)) { System.out.println("  ok    " + what); return; }
        fails++;
        System.out.println("  FAIL  " + what + ": want " + want + ", got " + got);
    }

    static final int W = RerunReapRule.WARM, U = RerunReapRule.UNKNOWN, C = RerunReapRule.COLD;
    static final int WAIT = RerunReapRule.WAIT, RERUN = RerunReapRule.RERUN, DONE = RerunReapRule.DONE,
            RETRY = RerunReapRule.RETRY, REMOVE = RerunReapRule.REMOVE, SD = RerunReapRule.STAND_DOWN;

    /** The reply table for one kind. fail is what a failed re-run gives: REMOVE for WARM, STAND_DOWN otherwise. */
    static void table(String k, int kind, int fail) {
        eq(k + " OK -> DONE", DONE, RerunReapRule.onReply("OK", 1, kind));
        eq(k + " ' OK ' -> DONE", DONE, RerunReapRule.onReply(" OK \n", 1, kind));
        eq(k + " GONE -> DONE", DONE, RerunReapRule.onReply("GONE", 1, kind));
        eq(k + " ERR-LIVE -> STAND_DOWN", SD, RerunReapRule.onReply("ERR-LIVE", 1, kind));
        eq(k + " ERR-PARKED -> STAND_DOWN", SD, RerunReapRule.onReply("ERR-PARKED", 1, kind));
        eq(k + " ERR-LIVE on the third try -> STAND_DOWN", SD, RerunReapRule.onReply("ERR-LIVE", 3, kind));
        for (String r : new String[] {"BUSY", "", null}) {
            String n = r == null ? "null" : "'" + r + "'";
            eq(k + " " + n + " try 1 -> RETRY", RETRY, RerunReapRule.onReply(r, 1, kind));
            eq(k + " " + n + " try 2 -> RETRY", RETRY, RerunReapRule.onReply(r, 2, kind));
            eq(k + " " + n + " try 3 -> failed", fail, RerunReapRule.onReply(r, 3, kind));
        }
        eq(k + " ERR -> failed", fail, RerunReapRule.onReply("ERR", 1, kind));
        eq(k + " WAT -> failed", fail, RerunReapRule.onReply("WAT", 1, kind));
    }

    public static void main(String[] a) {
        // R1: a WARM or UNKNOWN switch WAITs until RERUN_AFTER_MS and RERUNs at it.
        eq("RERUN_AFTER_MS is 45 000", 45_000L, RerunReapRule.RERUN_AFTER_MS);
        for (int kind : new int[] {W, U}) {
            String k = kind == W ? "WARM" : "UNKNOWN";
            eq(k + " switch at 0 -> WAIT", WAIT, RerunReapRule.afterSwitch(kind, 1000, 1000));
            eq(k + " switch at 44 999 -> WAIT", WAIT, RerunReapRule.afterSwitch(kind, 1000, 1000 + 44_999));
            eq(k + " switch at 45 000 -> RERUN", RERUN, RerunReapRule.afterSwitch(kind, 1000, 1000 + 45_000));
            eq(k + " switch at RERUN_AFTER_MS - 1 -> WAIT", WAIT,
                    RerunReapRule.afterSwitch(kind, 1000, 1000 + RerunReapRule.RERUN_AFTER_MS - 1));
            eq(k + " switch at RERUN_AFTER_MS -> RERUN", RERUN,
                    RerunReapRule.afterSwitch(kind, 1000, 1000 + RerunReapRule.RERUN_AFTER_MS));
        }
        // R2: a COLD switch never RERUNs.
        eq("COLD switch at 0 -> WAIT", WAIT, RerunReapRule.afterSwitch(C, 1000, 1000));
        eq("COLD switch at RERUN_AFTER_MS -> WAIT", WAIT,
                RerunReapRule.afterSwitch(C, 1000, 1000 + RerunReapRule.RERUN_AFTER_MS));
        eq("COLD switch at 10 x RERUN_AFTER_MS -> WAIT", WAIT,
                RerunReapRule.afterSwitch(C, 1000, 1000 + 10 * RerunReapRule.RERUN_AFTER_MS));
        // R3: the WARM reply table. R4: the same for UNKNOWN, every REMOVE a STAND_DOWN. A COLD record never asks,
        // but the rule stays safe for it too.
        table("WARM", W, REMOVE);
        table("UNKNOWN", U, SD);
        table("COLD", C, SD);
        // R5: afterOk REMOVEs after RERUN_AFTER_MS (the same for WARM and UNKNOWN: it takes no kind).
        eq("afterOk at RERUN_AFTER_MS - 1 -> WAIT", WAIT,
                RerunReapRule.afterOk(1000, 1000 + RerunReapRule.RERUN_AFTER_MS - 1));
        eq("afterOk at RERUN_AFTER_MS -> REMOVE", REMOVE,
                RerunReapRule.afterOk(1000, 1000 + RerunReapRule.RERUN_AFTER_MS));
        eq("afterOk at 45 000 -> REMOVE", REMOVE, RerunReapRule.afterOk(1000, 1000 + 45_000));
        // R6: a live daemon's own fallback (2 x reapSwitchWait 8 s + 2 x reapRemoveWait 12 s) always comes first.
        eq("RERUN_AFTER_MS >= 2*8 000 + 2*12 000", 1,
                RerunReapRule.RERUN_AFTER_MS >= 2 * 8_000L + 2 * 12_000L ? 1 : 0);
        eq("RETRY_MS x 3 == RERUN_AFTER_MS", RerunReapRule.RERUN_AFTER_MS, RerunReapRule.RETRY_MS * 3);
        eq("MAX_TRIES is 3", 3, RerunReapRule.MAX_TRIES);
        // kindOf: an unanswered probe is UNKNOWN, never WARM.
        eq("kindOf null -> UNKNOWN", U, RerunReapRule.kindOf(null));
        eq("kindOf '' -> UNKNOWN", U, RerunReapRule.kindOf(""));
        eq("kindOf blank -> UNKNOWN", U, RerunReapRule.kindOf("  \n"));
        eq("kindOf NONE -> WARM", W, RerunReapRule.kindOf("NONE"));
        eq("kindOf PENDING -> WARM", W, RerunReapRule.kindOf("PENDING"));
        eq("kindOf COLDLOCK -> COLD", C, RerunReapRule.kindOf("COLDLOCK 13 nokey nopin x"));
        // replyClass: a log token, never the raw reply.
        eqs("class OK", "OK", RerunReapRule.replyClass("OK"));
        eqs("class ERR-PARKED", "ERR-PARKED", RerunReapRule.replyClass(" ERR-PARKED\n"));
        eqs("class ''", "no-answer", RerunReapRule.replyClass(""));
        eqs("class null", "no-answer", RerunReapRule.replyClass(null));
        eqs("class WAT", "unknown", RerunReapRule.replyClass("WAT"));
        eqs("class x13secret", "unknown", RerunReapRule.replyClass("x13secret"));
        System.exit(fails == 0 ? 0 : 1);
    }
}
