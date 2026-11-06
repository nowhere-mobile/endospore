package com.nowhere.chooser;

import java.text.SimpleDateFormat;
import java.util.TimeZone;

/** NWP-20261120-10: the cases for PlanRunOrder (run by core/vendor-common/bin/test-plan-run-order-java.sh). */
public class PlanRunOrderCases {
    static int pass = 0, fail = 0;

    static void eq(String what, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) { pass++; System.out.println("  ok    " + what); }
        else { fail++; System.out.println("  FAIL  " + what + ": want " + want + ", got " + got); }
    }

    static final long GIB = 1L << 30;
    // Every date below is a literal, worked out with `date -u -d @$(( (through + 1) * epochsec ))`, never with df.
    static final String B = "OK credit=0 through=21019 epochsec=86400 sub=0 plangb=50";

    public static void main(String[] a) {
        final SimpleDateFormat df = new SimpleDateFormat("yyyy-MM-dd");
        df.setTimeZone(TimeZone.getTimeZone("UTC"));

        eq("two steps", "50 GB to 2027-01-22, then 10 GB to 2027-07-21",
                PlanRunOrder.line(B + " plans=50:20839,10:21019", df));
        eq("three steps", "50 GB to 2027-01-22, then 20 GB to 2027-07-21, then 10 GB to 2027-10-19",
                PlanRunOrder.line(B + " plans=50:20839,20:21019,10:21109", df));
        eq("plans= before epochsec= reads the same",
                "50 GB to 2027-01-22, then 10 GB to 2027-07-21",
                PlanRunOrder.line("OK credit=0 through=21019 plans=50:20839,10:21019 epochsec=86400 sub=0", df));
        final String two = PlanRunOrder.line(B + " plans=50:20839,10:21019", df);
        eq("the date is the day after through, not through (2027-01-21)", false,
                two != null && two.contains("2027-01-21"));
        eq("epochsec absent -> the weekly 604800", "1 GB to 2025-08-07, then 2 GB to 2027-07-08",
                PlanRunOrder.line("OK credit=0 through=3000 sub=0 plans=1:2900,2:3000", df));

        eq("one step -> null", null, PlanRunOrder.line(B + " plans=50:21019", df));
        eq("no plans= -> null", null, PlanRunOrder.line(B, df));
        eq("plans= empty -> null", null, PlanRunOrder.line(B + " plans=", df));
        eq("a non-number size -> null", null, PlanRunOrder.line(B + " plans=50:20839,x:1", df));
        eq("a step without a colon -> null", null, PlanRunOrder.line(B + " plans=50:20839,10", df));
        eq("a step with two colons -> null", null, PlanRunOrder.line(B + " plans=50:20839,10:1:2", df));
        eq("a zero size -> null", null, PlanRunOrder.line(B + " plans=50:20839,0:21019", df));
        eq("a zero end -> null", null, PlanRunOrder.line(B + " plans=50:20839,10:0", df));
        eq("an empty step -> null", null, PlanRunOrder.line(B + " plans=50:20839,", df));
        eq("a null reply -> null", null, PlanRunOrder.line(null, df));
        eq("NONE -> null", null, PlanRunOrder.line("NONE", df));
        eq("an ERR reply -> null", null, PlanRunOrder.line("ERR plans=50:20839,10:21019", df));
        eq("epochsec=0 -> null", null, PlanRunOrder.line("OK through=21019 epochsec=0 plans=50:20839,10:21019", df));

        // The three other GET-BILLING parsers ignore the new token: each answers the same with and without it.
        final long nowSec = 20750L * 86400;
        final String with = B + " plans=50:20839,10:21019";
        for (String extra : new String[] {"", " pending=1", " periods=3"}) {
            final String b0 = B + extra, b1 = with + extra;
            eq("PlanChoice.shouldAsk" + extra, PlanChoice.shouldAsk(b0, nowSec), PlanChoice.shouldAsk(b1, nowSec));
            for (long ent : new long[] {-1, 0, 50 * GIB}) {
                eq("PlanReport.offer" + extra + " entitled " + ent,
                        PlanReport.offer(b0, ent, nowSec), PlanReport.offer(b1, ent, nowSec));
                eq("PlanExpiry.stage" + extra + " entitled " + ent,
                        PlanExpiry.stage(b0, ent, nowSec), PlanExpiry.stage(b1, ent, nowSec));
            }
        }
        // And near the term's end, where PlanExpiry has a notice to give.
        final long late = 21015L * 86400;
        eq("PlanExpiry.stage near the end", PlanExpiry.stage(B, 50 * GIB, late), PlanExpiry.stage(with, 50 * GIB, late));
        eq("PlanExpiry.stage near the end is a notice (the case reaches a stage)", true,
                PlanExpiry.stage(with, 50 * GIB, late) != PlanExpiry.NONE);

        System.out.println(pass + " passed, " + fail + " failed");
        if (fail > 0) System.exit(1);
    }
}
