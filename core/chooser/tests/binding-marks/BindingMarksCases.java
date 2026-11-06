package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** Cases for BindingMarks (NWP-20261110-07). An exception in a case is a FAIL, not a crash. The ICCIDs are test
 *  values, not a real SIM's. */
public final class BindingMarksCases {
    private static int failed = 0, ran = 0;

    private static void check(String name, boolean cond) {
        ran++;
        if (!cond) { failed++; System.out.println("--- FAIL " + name); }
    }

    private static String show(String r) { return r == null ? "null" : "\"" + r.replace("\r", "\\r") + "\""; }

    private static boolean noDigit(String s) { return s != null && !s.matches("(?s).*[0-9].*"); }

    public static void main(String[] args) {
        try {
            run();
        } catch (Throwable t) {
            failed++;
            System.out.println("--- FAIL threw " + t);
        }
        System.out.println(ran + " checks, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }

    private static final String A = "89010000000000000011";
    private static final String B = "89010000000000000012";

    private static void run() {
        // K1: no REBUILT line -> every SIM no line names is the owner's line, an empty ICCID too.
        BindingMarks k1 = BindingMarks.parse(Arrays.asList("OK", "3|" + B + "|bGFiZWw=|open|1"));
        check("K1 not rebuilt", !k1.rebuilt);
        check("K1 ownersLine(8901)", k1.ownersLine("8901"));
        check("K1 ownersLine(A)", k1.ownersLine(A));
        check("K1 ownersLine(\"\") outside a rebuilt file", k1.ownersLine(""));

        // K2: REBUILT and MINE A -> only A (padded or not) is the owner's line; B, "" and null are not.
        BindingMarks k2 = BindingMarks.parse(Arrays.asList("OK", "REBUILT", "MINE " + A));
        check("K2 rebuilt", k2.rebuilt);
        check("K2 ownersLine(A)", k2.ownersLine(A));
        check("K2 ownersLine(A + F)", k2.ownersLine(A + "F"));
        check("K2 ownersLine(A + f)", k2.ownersLine(A + "f"));
        check("K2 ownersLine(B) is false", !k2.ownersLine(B));
        check("K2 ownersLine(\"\") is false", !k2.ownersLine(""));
        check("K2 ownersLine(\" \") is false", !k2.ownersLine(" "));
        check("K2 ownersLine(null) is false", !k2.ownersLine(null));
        BindingMarks k2p = BindingMarks.parse(Arrays.asList("OK", "REBUILT", "MINE " + A + "F\r"));
        check("K2 a padded MINE mark matches the unpadded ICCID", k2p.ownersLine(A));
        BindingMarks k2n = BindingMarks.parse(Arrays.asList("OK", "REBUILT"));
        check("K2 REBUILT with no MINE mark: A is not the owner's line", !k2n.ownersLine(A));

        // K3: a five-field binding line, DAMAGED and a MINE line that holds '|' are not marks.
        BindingMarks k3 = BindingMarks.parse(Arrays.asList("OK", "REBUILT", "3|" + A + "|bGFiZWw=|open|1", "DAMAGED"));
        check("K3 a binding line is not a mark", !k3.ownersLine(A));
        BindingMarks k3b = BindingMarks.parse(Arrays.asList("OK", "REBUILT", "MINE " + A + "|x"));
        check("K3 MINE a|b is not a mark", !k3b.ownersLine(A) && !k3b.ownersLine(A + "|x"));
        BindingMarks k3c = BindingMarks.parse(Arrays.asList("OK", "MINE " + A, "DAMAGED"));
        check("K3 DAMAGED does not make a file rebuilt", !k3c.rebuilt && k3c.ownersLine(B));
        BindingMarks k3d = BindingMarks.parse(Arrays.asList("OK", "REBUILT", "MINE "));
        check("K3 an empty MINE mark is not a mark", !k3d.ownersLine(A) && !k3d.ownersLine(""));

        // K4: mineOutcome's replies.
        String[][] want = {
            { "OK", BindingMarks.DONE }, { "OK\r", BindingMarks.DONE }, { "OK UNCHANGED", BindingMarks.DONE },
            { "OK NOTREBUILT", BindingMarks.DONE }, { "ERR repair", BindingMarks.REPAIR_FIRST },
            { "BUSY", BindingMarks.BUSY }, { "ERR damaged", BindingMarks.DAMAGED },
            { "ERR io", BindingMarks.FAILED }, { "ERR", BindingMarks.FAILED }, { "DENIED", BindingMarks.FAILED },
            { "", BindingMarks.FAILED }, { null, BindingMarks.FAILED },
        };
        for (String[] c : want) {
            String got = BindingMarks.mineOutcome(c[0]);
            check("K4 mineOutcome(" + show(c[0]) + ") is " + show(c[1]) + ", got " + show(got), c[1].equals(got));
            check("K4 mineOutcome(" + show(c[0]) + ") holds no digit", noDigit(got));
            boolean back = "OK".equals(c[0]) || "OK\r".equals(c[0]);
            check("K4 mineBack(" + show(c[0]) + ") is " + back, BindingMarks.mineBack(c[0]) == back);
        }
        check("K4 the five outcomes differ", new java.util.HashSet<>(Arrays.asList(BindingMarks.DONE,
                BindingMarks.REPAIR_FIRST, BindingMarks.BUSY, BindingMarks.DAMAGED, BindingMarks.FAILED)).size() == 5);
        check("K4 REPAIR_FIRST is the decided wording", "Repair SIM bindings first".equals(BindingMarks.REPAIR_FIRST));

        // K5: fail closed. NONE (no file) is not rebuilt; no reply, null and ERR damaged give no owner's line.
        check("K5 NONE: ownersLine(8901)", BindingMarks.parse(Collections.singletonList("NONE")).ownersLine("8901"));
        List<String> empty = Collections.emptyList();
        check("K5 an empty reply: no owner's line", !BindingMarks.parse(empty).ownersLine(A));
        check("K5 a null reply: no owner's line", !BindingMarks.parse(null).ownersLine(A));
        check("K5 ERR damaged: no owner's line", !BindingMarks.parse(Collections.singletonList("ERR damaged")).ownersLine(A));
        check("K5 BUSY: no owner's line", !BindingMarks.parse(Collections.singletonList("BUSY")).ownersLine(A));
    }
}
