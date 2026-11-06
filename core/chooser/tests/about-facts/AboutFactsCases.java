package com.nowhere.chooser;

/** Cases for AboutFacts (NWP-20261030-07): the gate's About page maps raw properties to words, never echoing an unknown one. */
public final class AboutFactsCases {
    private static int fails = 0;
    private static int ran = 0;

    private static void eq(String label, String got, String want) {
        ran++;
        if (want == null ? got != null : !want.equals(got)) {
            fails++;
            System.out.println("  FAIL  " + label + ": got <" + got + "> want <" + want + ">");
        }
    }

    private static void yes(String label, boolean ok) {
        ran++;
        if (!ok) {
            fails++;
            System.out.println("  FAIL  " + label);
        }
    }

    public static void main(String[] args) {
        final String green = "Verified — checked at boot against the phone maker's key";
        final String yellow = "Verified with a custom key — checked at boot against a key installed on this phone, "
                + "not the phone maker's. A locked Nowhere phone boots this way.";
        final String orange = "Not verified — the bootloader is unlocked, so the software was not checked at boot";
        final String nr = "Not reported";

        eq("green", AboutFacts.bootState("green"), green);
        eq("yellow", AboutFacts.bootState("yellow"), yellow);
        eq("orange", AboutFacts.bootState("orange"), orange);
        eq("GREEN", AboutFacts.bootState("GREEN"), green);
        eq("Yellow padded", AboutFacts.bootState(" Yellow "), yellow);
        eq("orange newline", AboutFacts.bootState("orange\n"), orange);
        eq("Green tab", AboutFacts.bootState("Green\t"), green);
        yes("three states distinct", !green.equals(yellow) && !yellow.equals(orange) && !green.equals(orange));

        String[] unknown = {"red", "GREENISH", "", "   ", "greenyellow", "unknown-state"};
        for (String u : unknown) {
            String got = AboutFacts.bootState(u);
            eq("bootState unknown <" + u + ">", got, nr);
            yes("bootState does not echo <" + u + ">", u.trim().isEmpty() || !got.contains(u));
        }
        eq("bootState null", AboutFacts.bootState(null), nr);

        eq("lock 1", AboutFacts.bootloader("1"), "Locked");
        eq("lock 1 padded", AboutFacts.bootloader(" 1 "), "Locked");
        eq("lock 0", AboutFacts.bootloader("0"), "Unlocked");
        eq("lock true", AboutFacts.bootloader("true"), nr);
        eq("lock empty", AboutFacts.bootloader(""), nr);
        eq("lock 2", AboutFacts.bootloader("2"), nr);
        eq("lock null", AboutFacts.bootloader(null), nr);

        eq("orNotReported value", AboutFacts.orNotReported("  2026100100 "), "2026100100");
        eq("orNotReported empty", AboutFacts.orNotReported(""), nr);
        eq("orNotReported blank", AboutFacts.orNotReported("  "), nr);
        eq("orNotReported null", AboutFacts.orNotReported(null), nr);

        eq("TITLE", AboutFacts.TITLE, "About");
        eq("CANNOT_PROVE", AboutFacts.CANNOT_PROVE,
                "These values are reported by the software running on this phone. Software that is not genuine can "
                + "report them falsely, so this page cannot prove the phone runs a genuine image.");

        if (fails > 0) {
            System.out.println(fails + " of " + ran + " cases FAILED");
            System.exit(1);
        }
        System.out.println(ran + " cases ok");
    }
}
