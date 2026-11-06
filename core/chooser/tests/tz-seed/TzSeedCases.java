package com.nowhere.chooser;

/** Cases for TzSeed.pick (Q148). A violation is also recorded when the predicate is asked about null or "". */
public final class TzSeedCases {
    private static int bad = 0;
    private static int badCalls = 0;

    private static void check(String name, String got, String want) {
        if (want.equals(got)) { System.out.println("PASS " + name); return; }
        System.out.println("FAIL " + name + ": got <" + got + "> want <" + want + ">");
        bad++;
    }

    public static void main(String[] args) {
        final String d = "America/New_York";
        java.util.function.Predicate<String> known = z -> {
            if (z == null || z.isEmpty()) badCalls++;
            return "Europe/Berlin".equals(z) || d.equals(z);
        };
        check("known last zone is the seed", TzSeed.pick("Europe/Berlin", d, known), "Europe/Berlin");
        check("unknown last zone falls to the default", TzSeed.pick("Mars/Olympus", d, known), d);
        check("null last zone falls to the default", TzSeed.pick(null, d, known), d);
        check("empty last zone falls to the default", TzSeed.pick("", d, known), d);
        check("the predicate decides", TzSeed.pick("Europe/Berlin", d, z -> false), d);
        if (badCalls != 0) { System.out.println("FAIL predicate asked about null or empty " + badCalls + " time(s)"); bad++; }
        else System.out.println("PASS predicate never asked about null or empty");
        System.exit(bad == 0 ? 0 : 1);
    }
}
