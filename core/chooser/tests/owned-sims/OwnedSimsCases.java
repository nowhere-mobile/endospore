package com.nowhere.chooser;

import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** NWP-20261023-12: the owned-SIM reply parse rules, run against the real OwnedSims.java. Exit 1 on any failed case
 *  failed case. */
public class OwnedSimsCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("  FAIL " + what); } else System.out.println("  ok   " + what);
    }

    static Set<String> set(String... s) { return new LinkedHashSet<>(Arrays.asList(s)); }

    static List<String> l(String... s) { return Arrays.asList(s); }

    static void liveNull(String what, List<String> in) { check(OwnedSims.parseLive(in) == null, "parseLive " + what + " -> null"); }

    static void live(String what, List<String> in, int uid, Set<String> owned) {
        OwnedSims.Live v = OwnedSims.parseLive(in);
        check(v != null && v.uid == uid && v.owned.equals(owned), "parseLive " + what + " -> uid " + uid + " " + owned);
    }

    static void ownedNull(String what, List<String> in) { check(OwnedSims.parseOwned(in) == null, "parseOwned " + what + " -> null"); }

    static void owned(String what, List<String> in, Set<String> want) {
        Set<String> got = OwnedSims.parseOwned(in);
        check(got != null && got.equals(want), "parseOwned " + what + " -> " + want);
    }

    static void tgt(String what, Set<String> owned, String iccid, int want) {
        check(OwnedSims.target(owned, iccid) == want, "target " + what);
    }

    public static void main(String[] a) {
        liveNull("null", null);
        liveNull("[]", l());
        liveNull("[NONE]", l("NONE"));
        liveNull("[OK]", l("OK"));
        liveNull("[OK abc]", l("OK abc"));
        liveNull("[OK 0]", l("OK 0"));
        liveNull("[OK -3]", l("OK -3"));
        liveNull("[ERR x]", l("ERR x"));
        live("[OK 10]", l("OK 10"), 10, set());
        live("[OK 10, 8901, blank, 8902]", l("OK 10", "8901", "  ", "8902"), 10, set("8901", "8902"));
        live("[ OK 10 , 8901 ]", l(" OK 10 ", " 8901 "), 10, set("8901"));

        ownedNull("null", null);
        ownedNull("[]", l());
        ownedNull("[ERR]", l("ERR"));
        ownedNull("[OKAY, x]", l("OKAY", "x"));
        owned("[OK]", l("OK"), set());
        owned("[OK, 8901, OK, blank]", l("OK", "8901", "OK", ""), set("8901"));

        final String a19 = "8944000000000001234", b19 = "8944000000000009999";
        tgt("owned, same ICCID -> VISIBLE", set(a19), a19, OwnedSims.VISIBLE);
        tgt("owned 19 digits, iccid + 'F' -> VISIBLE", set(a19), a19 + "F", OwnedSims.VISIBLE);
        tgt("owned 19 digits, iccid + 'f' -> VISIBLE", set(a19), a19 + "f", OwnedSims.VISIBLE);
        tgt("owned with 'F', iccid without -> VISIBLE", set(a19 + "F"), a19, OwnedSims.VISIBLE);
        tgt("foreign ICCID -> HIDE", set(a19), b19, OwnedSims.HIDE);
        tgt("null ICCID -> SKIP", set(a19), null, OwnedSims.SKIP);
        tgt("empty ICCID -> SKIP", set(a19), "", OwnedSims.SKIP);
        tgt("blank ICCID -> SKIP", set(a19), "  ", OwnedSims.SKIP);
        tgt("owned empty -> HIDE", set(), a19, OwnedSims.HIDE);
        tgt("owned null -> SKIP", null, a19, OwnedSims.SKIP);

        check(OwnedSims.stuck(OwnedSims.VISIBLE, null), "stuck VISIBLE + null -> true");
        check(!OwnedSims.stuck(OwnedSims.VISIBLE, 0), "stuck VISIBLE + 0 -> false");
        check(OwnedSims.stuck(OwnedSims.HIDE, 0), "stuck HIDE + 0 -> true");
        check(!OwnedSims.stuck(OwnedSims.HIDE, null), "stuck HIDE + null -> false");
        check(!OwnedSims.stuck(OwnedSims.HIDE, 11), "stuck HIDE + 11 -> false");
        check(!OwnedSims.stuck(OwnedSims.SKIP, null), "stuck SKIP + null -> false");
        check(!OwnedSims.stuck(OwnedSims.SKIP, 0), "stuck SKIP + 0 -> false");
        check(!OwnedSims.stuck(OwnedSims.SKIP, 11), "stuck SKIP + 11 -> false");

        System.out.println(fails == 0 ? "all cases pass" : fails + " case(s) failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
