// Cases for HeldElsewhereCopy (NWP-20261120-15). Run by run.sh; prints "FAIL <case>" per failure and exits 1.
public class HeldElsewhereCases {
    static int fails = 0;

    static final String RELEASE = "These are in use on your other device, so they won't open here. Each opens here "
            + "once that device releases it, signs out or uninstalls it, or about an hour after that device "
            + "is switched off.";

    static void ok(String name, boolean cond, String detail) {
        if (cond) System.out.println("  ok   " + name);
        else { System.out.println("FAIL " + name + ": " + detail); fails++; }
    }

    static int count(String s, String sub) {
        int n = 0;
        for (int i = s.indexOf(sub); i >= 0; i = s.indexOf(sub, i + 1)) n++;
        return n;
    }

    public static void main(String[] a) {
        ok("c1 body(null) is null", HeldElsewhereCopy.body(null) == null, "got " + HeldElsewhereCopy.body(null));
        String e = HeldElsewhereCopy.body(new java.util.ArrayList<String>());
        ok("c2 body(empty) is null", e == null, "got " + e);

        String two = HeldElsewhereCopy.body(java.util.Arrays.asList("A", "B"));
        ok("c3 body([A, B]) is drawn", two != null, "got null");
        if (two == null) two = "";
        ok("c3 • A once", count(two, "• A\n") == 1, "got " + two);
        ok("c3 • B once", count(two, "• B\n") == 1, "got " + two);
        ok("c3 • A before • B", two.indexOf("• A\n") >= 0
                && two.indexOf("• A\n") < two.indexOf("• B\n"), "got " + two);
        ok("c3 ends with a blank line and the release sentence", two.endsWith("\n\n" + RELEASE), "got " + two);
        ok("c3 nothing but the list and the sentence",
                two.equals("• A\n• B\n\n" + RELEASE), "got " + two);

        String one = HeldElsewhereCopy.body(java.util.Collections.singletonList("A"));
        ok("c4 body([A]) holds • A once", one != null && count(one, "• A\n") == 1, "got " + one);

        ok("c5 HEADING", "Held by your other device".equals(HeldElsewhereCopy.HEADING), "got " + HeldElsewhereCopy.HEADING);
        ok("c5 WHERE", "your other device".equals(HeldElsewhereCopy.WHERE), "got " + HeldElsewhereCopy.WHERE);

        String[] all = {HeldElsewhereCopy.WHERE, HeldElsewhereCopy.HEADING, HeldElsewhereCopy.UNREADABLE, two, one};
        boolean phone = false;
        for (String s : all) if (s != null && s.toLowerCase(java.util.Locale.ROOT).contains("phone")) phone = true;
        ok("c6 no string says phone (the decision's word is device)", !phone, "a string contains \"phone\"");

        String u = HeldElsewhereCopy.UNREADABLE;
        ok("c7 UNREADABLE is non-empty and not part of the body",
                u != null && !u.isEmpty() && !u.equals(two) && !two.contains(u), "got " + u);

        // H1-H3 (NWP-20261128-23): the holder's name, per the 2026-09-12 rule, with WHERE as its unknown branch.
        String h = HeldElsewhereCopy.heading("Pixel 8");
        ok("H1 heading(Pixel 8)", "Held by Pixel 8".equals(h), "got " + h);
        String hn = HeldElsewhereCopy.heading(null);
        ok("H1 heading(null) is HEADING", HeldElsewhereCopy.HEADING.equals(hn), "got " + hn);
        String he = HeldElsewhereCopy.heading("");
        ok("H1 heading(\"\") is HEADING", HeldElsewhereCopy.HEADING.equals(he), "got " + he);
        String hw = HeldElsewhereCopy.heading(HeldElsewhereCopy.WHERE);
        ok("H1 heading(WHERE) is HEADING", HeldElsewhereCopy.HEADING.equals(hw), "got " + hw);

        java.util.List<String> ab = java.util.Arrays.asList("A", "B");
        String named = HeldElsewhereCopy.body(ab, "Pixel 8");
        String cond = "Each opens here once that device releases it, signs out or uninstalls it, or about an "
                + "hour after that device is switched off.";
        ok("H2 body names the holder", named != null && named.contains("in use on Pixel 8"), "got " + named);
        ok("H2 body keeps the release conditions", named != null && named.endsWith(cond), "got " + named);
        ok("H2 body does not say your other device", named != null && !named.contains("your other device"),
                "got " + named);
        ok("H2 the exact text",
                ("• A\n• B\n\nThese are in use on Pixel 8, so they won't open here. " + cond).equals(named),
                "got " + named);

        String plain = HeldElsewhereCopy.body(ab);
        String bn = HeldElsewhereCopy.body(ab, null);
        ok("H3 body(l, null) is body(l)", plain != null && plain.equals(bn), "got " + bn);
        String bw = HeldElsewhereCopy.body(ab, HeldElsewhereCopy.WHERE);
        ok("H3 body(l, WHERE) is body(l)", plain != null && plain.equals(bw), "got " + bw);
        String be = HeldElsewhereCopy.body(ab, "");
        ok("H3 body(l, \"\") is body(l)", plain != null && plain.equals(be), "got " + be);
        String bz = HeldElsewhereCopy.body(new java.util.ArrayList<String>(), "Pixel 8");
        ok("H3 body(empty, Pixel 8) is null", bz == null, "got " + bz);

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
    }
}
