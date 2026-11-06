package com.nowhere.chooser;

/**
 * NWP-20261124-09: PlayAtCreate under javac, compiled as-is with PlayChoice. Run by
 * core/vendor-common/bin/test-play-at-create-java.sh, which also pins the wiring these cases cannot see.
 *
 *   C1  QUESTION is the decided text verbatim (docs/product-decisions.md, 2026-10-26), typed here from the decision.
 *   C2  offered only with the GrapheneOS App Store installed AND in create mode (Diaspore never shows it).
 *   C3  value(on) is "1", the same literal as PlayChoice.raw(ON); value(off) is null (off sends and writes nothing).
 *   C4  accepts exactly "1": "0", "", null, padded and look-alike values are refused.
 */
public final class PlayAtCreateCases {
    private static int runs, fails;

    private static void check(String name, boolean ok, String why) {
        runs++;
        if (ok) System.out.println("  PASS " + name);
        else { fails++; System.out.println("  FAIL " + name + ": " + why); }
    }

    public static void main(String[] a) {
        String decided = "Use Google Play apps on this profile? Some apps (banking, maps, messaging) need it. "
                + "It downloads about 130 MB the first time.";
        check("C1 QUESTION is the decided text verbatim", decided.equals(PlayAtCreate.QUESTION),
                "QUESTION=" + PlayAtCreate.QUESTION);

        check("C2 offered with the App Store, in create mode", PlayAtCreate.offered(true, true), "false");
        check("C2 not offered without the App Store (Diaspore)", !PlayAtCreate.offered(false, true), "true");
        check("C2 not offered outside create mode", !PlayAtCreate.offered(true, false), "true");
        check("C2 not offered without either", !PlayAtCreate.offered(false, false), "true");

        check("C3 value(on) is \"1\"", "1".equals(PlayAtCreate.value(true)), "value(true)=" + PlayAtCreate.value(true));
        check("C3 value(on) is PlayChoice.raw(ON)",
                PlayChoice.raw(PlayChoice.State.ON).equals(PlayAtCreate.value(true)), "value(true)=" + PlayAtCreate.value(true));
        check("C3 value(on) parses as ON", PlayChoice.parse(PlayAtCreate.value(true)) == PlayChoice.State.ON,
                "parse=" + PlayChoice.parse(PlayAtCreate.value(true)));
        check("C3 value(off) is null (nothing is sent or written)", PlayAtCreate.value(false) == null,
                "value(false)=" + PlayAtCreate.value(false));

        check("C4 accepts \"1\"", PlayAtCreate.accepts("1"), "false");
        for (String bad : new String[] {"0", "", null, " 1x", " 1", "1 ", "on", "true", "11", "junk"}) {
            check("C4 refuses " + (bad == null ? "null" : "\"" + bad + "\""), !PlayAtCreate.accepts(bad), "accepted");
        }

        System.out.println(fails == 0 ? "ALL " + runs + " PASS" : fails + " of " + runs + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
