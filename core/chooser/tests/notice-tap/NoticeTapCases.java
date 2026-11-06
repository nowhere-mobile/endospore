package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** NWP-20261105-06: the cases for NoticeTap (run by core/vendor-common/bin/test-notice-tap-java.sh). */
public class NoticeTapCases {
    static int pass = 0, fail = 0;

    static void eq(String what, Object want, Object got) {
        if (want.equals(got)) { pass++; System.out.println("  ok    " + what); }
        else { fail++; System.out.println("  FAIL  " + what + ": want " + want + ", got " + got); }
    }

    static String[] e(String label, String count, boolean unbound) {
        return new String[]{label, "message", count, "false", "line " + label, unbound ? "true" : "false"};
    }

    @SafeVarargs
    static List<String[]> l(String[]... n) { return new ArrayList<>(Arrays.asList(n)); }

    public static void main(String[] a) {
        eq("no list -> NONE", NoticeTap.NONE, NoticeTap.action(null, true));
        eq("no notices -> NONE", NoticeTap.NONE, NoticeTap.action(l(), true));
        for (String c : new String[]{"1", "3"})
            for (boolean s : new boolean[]{true, false}) {
                eq("one bound notice, count " + c + ", secret " + s + " -> NONE", NoticeTap.NONE,
                        NoticeTap.action(l(e("Sim1", c, false)), s));
            }
        for (String c : new String[]{"1", "3"}) {
            eq("one unassigned notice, count " + c + ", secret set -> VERIFY", NoticeTap.VERIFY,
                    NoticeTap.action(l(e("x", c, true)), true));
            eq("one unassigned notice, count " + c + ", no secret -> NONE", NoticeTap.NONE,
                    NoticeTap.action(l(e("x", c, true)), false));
        }
        eq("two bound notices, no secret -> POPUP", NoticeTap.POPUP, NoticeTap.action(l(e("a", "1", false), e("b", "1", false)), false));
        eq("two bound notices, secret -> POPUP", NoticeTap.POPUP, NoticeTap.action(l(e("a", "1", false), e("b", "1", false)), true));
        eq("two notices, one unassigned, secret -> POPUP", NoticeTap.POPUP, NoticeTap.action(l(e("a", "1", false), e("b", "2", true)), true));
        eq("two notices, one unassigned, no secret -> POPUP", NoticeTap.POPUP, NoticeTap.action(l(e("a", "1", false), e("b", "2", true)), false));

        eq("inboxButton: unassigned + secret", true, NoticeTap.inboxButton(e("u", "1", true), true));
        eq("inboxButton: unassigned, no secret", false, NoticeTap.inboxButton(e("u", "1", true), false));
        eq("inboxButton: bound + secret", false, NoticeTap.inboxButton(e("b", "1", false), true));
        eq("inboxButton: bound, no secret", false, NoticeTap.inboxButton(e("b", "1", false), false));
        eq("inboxButton: an old five-field entry", false, NoticeTap.inboxButton(new String[]{"u", "message", "1", "false", "t"}, true));
        eq("inboxButton: null", false, NoticeTap.inboxButton(null, true));

        eq("lines keep the order and hold field 4 only", Arrays.asList("line b", "line a", "line c"),
                NoticeTap.lines(l(e("b", "2", false), e("a", "1", true), e("c", "9", false))));
        eq("lines of nothing", 0, NoticeTap.lines(null).size());

        System.out.println("passed " + pass + ", failed " + fail);
        System.exit(fail == 0 ? 0 : 1);
    }
}
