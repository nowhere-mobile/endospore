package com.nowhere.chooser;

/** NWP-20261127-08: test-placeholder-outcomes-java.sh compiles this with PlaceholderTally.java and a
 *  SideloadedVerdict.java the suite extracts from ProfileActivity.java, ALONE, and runs it. */
public final class PlaceholderOutcomesCases {
    static int bad = 0;

    static void eq(String id, String what, Object want, Object got) {
        if (want.equals(got)) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        bad++;
    }

    static PlaceholderTally tally(int raised, int noMeta, int refused, int groupDep, int error) {
        PlaceholderTally t = new PlaceholderTally();
        t.raised = raised; t.noMeta = noMeta; t.refused = refused; t.groupDep = groupDep; t.error = error;
        return t;
    }

    public static void main(String[] a) {
        // P1: the wire order and the clamp.
        int b = bad;
        eq("P1", "a new tally", "0 0 0 0 0", new PlaceholderTally().line());
        eq("P1", "1..5 in field order", "1 2 3 4 5", tally(1, 2, 3, 4, 5).line());
        eq("P1", "99999 kept", "99999 0 0 0 0", tally(99999, 0, 0, 0, 0).line());
        eq("P1", "100000 clamped", "0 99999 0 0 0", tally(0, 100000, 0, 0, 0).line());
        eq("P1", "-3 clamped", "0 0 0 0 0", tally(0, 0, -3, 0, 0).line());
        eq("P1", "MAX_VALUE clamped", "0 0 0 99999 0", tally(0, 0, 0, Integer.MAX_VALUE, 0).line());
        eq("P1", "MIN_VALUE clamped", "0 0 0 0 0", tally(0, 0, 0, 0, Integer.MIN_VALUE).line());
        if (bad == b) System.out.println("ok P1 line() is \"raised noMeta refused groupDep error\", each clamped to 0..99999");

        // P2: any().
        b = bad;
        eq("P2", "any() on a new tally", false, new PlaceholderTally().any());
        eq("P2", "any() raised=1", true, tally(1, 0, 0, 0, 0).any());
        eq("P2", "any() noMeta=1", true, tally(0, 1, 0, 0, 0).any());
        eq("P2", "any() refused=1", true, tally(0, 0, 1, 0, 0).any());
        eq("P2", "any() groupDep=1", true, tally(0, 0, 0, 1, 0).any());
        eq("P2", "any() error=1", true, tally(0, 0, 0, 0, 1).any());
        if (bad == b) System.out.println("ok P2 any() is false on a new tally and true for each counter alone");

        // P3: the sideloaded decision.
        b = bad;
        for (String x : new String[] { null, "", "com.android.vending", "com.example.other" })
            eq("P3", "verdict(" + x + ", notFound)", false, SideloadedVerdict.sideloadedVerdict(x, true));
        eq("P3", "verdict(null, found)", true, SideloadedVerdict.sideloadedVerdict(null, false));
        eq("P3", "verdict(\"\", found)", true, SideloadedVerdict.sideloadedVerdict("", false));
        for (String s : new String[] { "org.fdroid.fdroid", "com.android.vending", "com.aurora.store",
                "com.nowhere.chooser", "app.grapheneos.apps" })
            eq("P3", "verdict(" + s + ", found)", false, SideloadedVerdict.sideloadedVerdict(s, false));
        eq("P3", "verdict(com.example.other, found)", true, SideloadedVerdict.sideloadedVerdict("com.example.other", false));
        if (bad == b) System.out.println("ok P3 not found -> false; no installer or an unknown one -> true; a known store -> false");

        if (bad > 0) System.exit(1);
    }
}
