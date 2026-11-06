package com.nowhere.chooser;

/** Cases for ReapRearm.uid (NWP-20261031-03). Exit 0 when all pass, 1 otherwise. */
public class ReapRearmCases {
    static int fails = 0;

    static void eq(String what, int want, int got) {
        if (want == got) { System.out.println("  ok    " + what); return; }
        fails++;
        System.out.println("  FAIL  " + what + ": want " + want + ", got " + got);
    }

    public static void main(String[] a) {
        eq("REARM 10", 10, ReapRearm.uid("REARM 10"));
        eq("REARM 10 newline", 10, ReapRearm.uid("REARM 10\n"));
        eq("padded", 10, ReapRearm.uid(" REARM 10 "));
        eq("REARM alone", -1, ReapRearm.uid("REARM"));
        eq("REARM x", -1, ReapRearm.uid("REARM x"));
        eq("REARM -1", -1, ReapRearm.uid("REARM -1"));
        eq("REARM -5", -1, ReapRearm.uid("REARM -5"));
        eq("REARM +10", -1, ReapRearm.uid("REARM +10"));
        eq("REARM 1 0", -1, ReapRearm.uid("REARM 1 0"));
        eq("overflow", -1, ReapRearm.uid("REARM 99999999999"));
        eq("LOCK 10", -1, ReapRearm.uid("LOCK 10"));
        eq("NONE", -1, ReapRearm.uid("NONE"));
        eq("null", -1, ReapRearm.uid(null));
        System.exit(fails == 0 ? 0 : 1);
    }
}
