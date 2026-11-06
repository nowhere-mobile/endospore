import java.util.HashSet;
import java.util.Set;

/** NWP-20261019-07: the SIM lines screen's eSIM wording and the inactive-eSIM count, run against the real helpers. */
public class EsimCases {
    static int failed = 0;

    static void check(boolean ok, String what) {
        if (!ok) { failed++; System.out.println("--- FAIL: " + what); }
    }

    static Set<Integer> ids(Integer... v) {
        Set<Integer> s = new HashSet<>();
        for (Integer i : v) s.add(i);
        return s;
    }

    public static void main(String[] a) {
        check(Lifted.esimNote(0, 0) == null, "no eSIM: no note");

        String one = Lifted.esimNote(1, 0), off = Lifted.esimNote(0, 1), mix = Lifted.esimNote(2, 1);
        check(one != null && one.contains("1 eSIM profile") && one.contains("0 switched off"), "(1,0) names one profile, none off: " + one);
        check(off != null && off.contains("1 eSIM profile") && off.contains("1 switched off"), "(0,1) names one profile, one off: " + off);
        check(mix != null && mix.contains("3 eSIM profiles") && mix.contains("1 switched off"), "(2,1) names 3 profiles, 1 off: " + mix);
        for (String n : new String[] { one, off, mix }) {
            if (n == null) { check(false, "a note is missing"); continue; }
            check(n.contains("Nowhere never deletes one."), "never-deletes sentence: " + n);
            check(n.contains("stays through sign-out and power-off"), "kept-on-the-phone sentence: " + n);
            String l = n.toLowerCase();
            check(!l.contains("remove") && !l.contains("delete it") && !l.contains("factory"), "no removal instruction, no factory claim: " + n);
            check(!n.contains("%") && !n.contains("{") && !n.contains("$"), "no format placeholder: " + n);
        }

        check(Lifted.simRowSummary("2 bound · Open", true).equals("eSIM · 2 bound · Open"), "embedded arm prefixes");
        String plain = "not bound";
        check(Lifted.simRowSummary(plain, false) == plain, "non-embedded is the same string");

        check(Lifted.countInactiveEmbedded(new int[] { 5 }, new boolean[] { true }, ids()) == 1, "inactive embedded counts");
        check(Lifted.countInactiveEmbedded(new int[] { 5 }, new boolean[] { true }, ids(5)) == 0, "active embedded does not");
        check(Lifted.countInactiveEmbedded(new int[] { 5 }, new boolean[] { false }, ids()) == 0, "inactive non-embedded does not");
        check(Lifted.countInactiveEmbedded(new int[0], new boolean[0], ids(1)) == 0, "empty arrays");
        check(Lifted.countInactiveEmbedded(new int[] { 1, 2, 3, 4 }, new boolean[] { true, true, false, true }, ids(2)) == 2, "mixed list");

        if (failed > 0) { System.out.println(failed + " case(s) failed"); System.exit(1); }
        System.out.println("PASS EsimCases");
    }
}
