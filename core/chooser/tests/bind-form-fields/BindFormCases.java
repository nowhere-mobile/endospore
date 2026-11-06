package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Cases for BindFormFields (NWP-20261021-04). Synthetic ICCIDs only. An exception in a case is a FAIL, not a crash. */
public final class BindFormCases {
    private static final String ICC = "8900000000000000001";   // 19 characters
    private static final String OTHER = "8900000000000000002";
    private static int failed = 0, ran = 0;

    private static String[] line(String icc, String label, String vis) {
        return new String[]{"-1", icc, "1 bound · " + vis, label, vis};
    }

    private static List<String[]> sums(String[]... rows) { return new ArrayList<>(Arrays.asList(rows)); }

    private static void expect(String name, String[] want, java.util.concurrent.Callable<String[]> got) {
        ran++;
        try {
            String[] g = got.call();
            if (!Arrays.equals(want, g)) {
                failed++;
                System.out.println("--- FAIL " + name + ": want " + Arrays.toString(want) + " got " + Arrays.toString(g));
            }
        } catch (Throwable t) {
            failed++;
            System.out.println("--- FAIL " + name + " threw " + t);
        }
    }

    private static void expectBool(String name, boolean want, java.util.concurrent.Callable<Boolean> got) {
        ran++;
        try {
            boolean g = got.call();
            if (g != want) { failed++; System.out.println("--- FAIL " + name + ": want " + want + " got " + g); }
        } catch (Throwable t) {
            failed++;
            System.out.println("--- FAIL " + name + " threw " + t);
        }
    }

    private static void expectSet(String name, java.util.Set<String> want, java.util.concurrent.Callable<java.util.Set<String>> got) {
        ran++;
        try {
            java.util.Set<String> g = got.call();
            if (!java.util.Objects.equals(want, g)) { failed++; System.out.println("--- FAIL " + name + ": want " + want + " got " + g); }
        } catch (Throwable t) {
            failed++;
            System.out.println("--- FAIL " + name + " threw " + t);
        }
    }

    private static java.util.Set<String> set(String... v) { return new java.util.HashSet<>(Arrays.asList(v)); }

    public static void main(String[] args) {
        final List<String[]> bound = sums(line(ICC, "Work", "private"));
        expect("a bound ICCID, nothing edited -> the stored label and vis", new String[]{"Work", "private", "1"},
                () -> BindFormFields.forBind(ICC, "", false, "open", false, bound));
        expect("b label edited to empty -> empty is kept", new String[]{"", "private", "1"},
                () -> BindFormFields.forBind(ICC, "", true, "open", false, bound));
        expect("c chip tapped -> the typed vis", new String[]{"Work", "notify", "1"},
                () -> BindFormFields.forBind(ICC, "", false, "notify", true, bound));
        expect("d unbound ICCID -> the typed values", new String[]{"Home", "open", "0"},
                () -> BindFormFields.forBind(ICC, "Home", true, "open", false, sums(line(OTHER, "Work", "private"))));
        expect("e stored ICCID padded with F -> matched", new String[]{"Work", "private", "1"},
                () -> BindFormFields.forBind(ICC, "", false, "open", false, sums(line(ICC + "F", "Work", "private"))));
        expect("f null sums -> null", null,
                () -> BindFormFields.forBind(ICC, "", false, "open", false, null));
        expect("g short damaged entry before the real line -> skipped", new String[]{"Work", "private", "1"},
                () -> BindFormFields.forBind(ICC, "", false, "open", false,
                        sums(new String[]{"-1", ICC, "damaged"}, line(ICC, "Work", "private"))));
        expect("h stored equal to typed -> kept 0", new String[]{"Work", "private", "0"},
                () -> BindFormFields.forBind(ICC, "Work", true, "private", true, bound));
        expect("i empty list -> the typed values", new String[]{"Home", "notify", "0"},
                () -> BindFormFields.forBind(ICC, "Home", true, "notify", true, new ArrayList<String[]>()));
        expect("j stored vis outside the three -> open", new String[]{"Work", "open", "1"},
                () -> BindFormFields.forBind(ICC, "", false, "notify", false, sums(line(ICC, "Work", "bogus"))));

        expectSet("k lineLabels null sums -> null", null, () -> BindFormFields.lineLabels(null, ICC));
        expectSet("l lineLabels no matching ICCID -> empty", set(),
                () -> BindFormFields.lineLabels(sums(line(OTHER, "Work", "open")), ICC));
        expectSet("m lineLabels two co-owner rows -> both", set("Work", ""),
                () -> BindFormFields.lineLabels(sums(line(ICC, "Work", "open"), line(ICC, "", "notify")), ICC));
        expectSet("n lineLabels stored ICCID padded with F -> matched", set("Work"),
                () -> BindFormFields.lineLabels(sums(line(ICC + "F", "Work", "open")), ICC));
        expectSet("o lineLabels three-field entry carrying this ICCID -> skipped, no exception", set("Work"),
                () -> BindFormFields.lineLabels(sums(new String[]{"-1", ICC, "damaged"}, line(ICC, "Work", "open")), ICC));
        expectSet("p lineLabels another ICCID's label never included", set("Home"),
                () -> BindFormFields.lineLabels(sums(line(ICC, "Home", "open"), line(OTHER, "Work", "open")), ICC));

        expectBool("iccEq null or empty -> false", false,
                () -> BindFormFields.iccEq(null, ICC) || BindFormFields.iccEq(ICC, "") || BindFormFields.iccEq(" ", " "));
        expectBool("iccEq tolerates a trailing F", true,
                () -> BindFormFields.iccEq(ICC + "F", ICC) && BindFormFields.iccEq(ICC, ICC + "f"));
        expectBool("iccEq tells two SIMs apart", false, () -> BindFormFields.iccEq(ICC, OTHER));

        if (failed > 0) { System.out.println("FAILED " + failed); System.exit(1); }
        System.out.println("ok: " + ran + " cases");
    }
}
