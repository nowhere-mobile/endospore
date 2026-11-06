package com.nowhere.chooser;

import java.util.Collections;
import java.util.Set;

/** NWP-20261122-13: the foreign-SIM line's words, its wire form and its counting rule, run against the real
 *  ForeignSimLine.java. The expected words are written here, from the h52 #3 drafts in docs/product-decisions.md
 *  (2026-11-01), not read from ForeignSimLine. Exit 1 on any failed case. */
public class ForeignSimLineCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("  FAIL " + what); } else System.out.println("  ok   " + what);
    }

    static ForeignSimLine.Case c(boolean ownsAny, int n) { return new ForeignSimLine.Case(ownsAny, n); }

    static void line(String what, ForeignSimLine.Case in, String want) {
        String got = ForeignSimLine.line(in);
        check(want == null ? got == null : want.equals(got), "line " + what + (want == null ? " -> null" : " -> the draft"));
    }

    static void refused(String in) {
        check(ForeignSimLine.decode(in) == null, "decode refuses [" + in + "]");
    }

    static void round(boolean ownsAny, int n) {
        String w = ForeignSimLine.encode(c(ownsAny, n));
        ForeignSimLine.Case back = ForeignSimLine.decode(w);
        check(w.equals((ownsAny ? "1 " : "0 ") + n) && back != null && back.ownsAny == ownsAny && back.notOwned == n,
                "encode/decode round trip (" + ownsAny + "," + n + ") via [" + w + "]");
    }

    public static void main(String[] a) {
        final String ownsOne = "This phone has another SIM that isn't assigned to this profile, so it can't be used here."
                + " The phone's owner manages it from owner mode at the gate.";
        final String ownsMany = "This phone has other SIMs that aren't assigned to this profile, so they can't be used"
                + " here. The phone's owner manages them from owner mode at the gate.";
        final String noneOne = "No SIM on this phone is assigned to this profile, so calls and texts can't be made here."
                + " Emergency calls still work. The phone's owner manages the SIM from owner mode at the gate.";
        final String noneMany = "No SIM on this phone is assigned to this profile, so calls and texts can't be made here."
                + " Emergency calls still work. The phone's owner manages the SIMs from owner mode at the gate.";

        line("(no case)", null, null);
        line("(true,0)", c(true, 0), null);
        line("(false,0)", c(false, 0), null);
        line("(true,1)", c(true, 1), ownsOne);
        line("(false,1)", c(false, 1), noneOne);
        line("(true,2)", c(true, 2), ownsMany);
        line("(false,3)", c(false, 3), noneMany);
        line("(true,3)", c(true, 3), ownsMany);
        line("(false,2)", c(false, 2), noneMany);

        refused(null);
        refused("");
        refused("1");
        refused("1 x");
        refused("2 1");
        refused("1 -1");
        refused(" 1 1");
        refused("1 1 ");
        refused("1 01");
        refused("1  1");
        round(true, 0);
        round(false, 1);
        round(true, 2);
        round(false, 17);
        boolean threw = false;
        try { c(true, -1); } catch (IllegalArgumentException e) { threw = true; }
        check(threw, "Case refuses a negative count");

        // the counting rule: only HIDE counts; SKIP (an unreadable ICCID, fail open) and VISIBLE (owned) do not
        check(!ForeignSimLine.notOwned(OwnedSims.SKIP), "notOwned(SKIP) is false");
        check(!ForeignSimLine.notOwned(OwnedSims.VISIBLE), "notOwned(VISIBLE) is false");
        check(ForeignSimLine.notOwned(OwnedSims.HIDE), "notOwned(HIDE) is true");
        Set<String> none = Collections.<String>emptySet();
        check(!ForeignSimLine.notOwned(OwnedSims.target(none, null)), "owns nothing: a null ICCID is not counted");
        check(!ForeignSimLine.notOwned(OwnedSims.target(none, "")), "owns nothing: an empty ICCID is not counted");
        check(!ForeignSimLine.notOwned(OwnedSims.target(none, "  ")), "owns nothing: a blank ICCID is not counted");
        check(ForeignSimLine.notOwned(OwnedSims.target(none, "8901000000000000001")), "owns nothing: a readable ICCID counts");
        Set<String> mine = Collections.singleton("8901000000000000001");
        check(!ForeignSimLine.notOwned(OwnedSims.target(mine, "8901000000000000001F")), "owns one: its own SIM is not counted");
        check(ForeignSimLine.notOwned(OwnedSims.target(mine, "8901000000000000002")), "owns one: another SIM counts");

        if (fails > 0) { System.out.println(fails + " case(s) FAILED"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
