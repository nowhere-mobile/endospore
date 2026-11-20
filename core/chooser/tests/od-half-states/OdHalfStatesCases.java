package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.function.Predicate;

/** NWP-20261204-14: OdHalfStates' cases, compiled with OdHalfStates.java ALONE and executed by
 *  core/vendor-common/bin/test-od-half-states-java.sh. Prints one 'ok   <case>' or 'FAIL <case> ...' line per case and
 *  exits 1 when any fails. Every value a case produces is also checked to hold no fixture package name and to have the
 *  exact shape "auto=<n> ondemand=<n> ondemand_ours=<n> notready=<n>". */
public final class OdHalfStatesCases {
    private static int bad = 0;
    private static final String A = "org.example.autoapp";
    private static final String B = "org.example.secondapp";
    private static final String O = "org.example.ondemandapp";
    private static final String N = "org.example.nocodeapp";
    private static final String[] NAMES = {A, B, O, N};

    private interface Case { String run(); }

    private static void check(String name, Case c) {
        String why;
        try {
            why = c.run();
        } catch (Throwable t) {
            why = "threw " + t;
        }
        if (why == null) {
            System.out.println("ok   " + name);
        } else {
            System.out.println("FAIL " + name + " -- " + why);
            bad = 1;
        }
    }

    private static String v(int a, int o, int m, int n) {
        return "auto=" + a + " ondemand=" + o + " ondemand_ours=" + m + " notready=" + n;
    }

    /** null when value equals want, has the fixed shape and holds no fixture name; else why not. */
    private static String expect(String value, String want) {
        if (value == null) return "got null";
        for (String p : NAMES) if (value.contains(p)) return "the value holds a package name: " + value;
        if (!value.matches("auto=\\d+ ondemand=\\d+ ondemand_ours=\\d+ notready=\\d+")) {
            return "the value has the wrong shape: " + value;
        }
        if (!value.equals(want)) return "got '" + value + "', want '" + want + "'";
        return null;
    }

    private static Predicate<String> in(String... pkgs) {
        Set<String> s = new HashSet<>(Arrays.asList(pkgs));
        return s::contains;
    }

    private static Set<String> set(String... pkgs) {
        return new HashSet<>(Arrays.asList(pkgs));
    }

    private static final Predicate<String> NONE = p -> false;

    private static String run(List<String> lines, Predicate<String> code, Predicate<String> restored,
                              Set<String> mat, int notready) {
        return OdHalfStates.reportValue(lines, code, restored, mat, notready);
    }

    public static void main(String[] args) {
        check("a1 auto with code and no restore counts", () -> expect(
                run(Arrays.asList(A + "\tauto"), in(A), NONE, set(), 0), v(1, 0, 0, 0)));
        check("a2 a restored auto app does not count", () -> expect(
                run(Arrays.asList(A + "\tauto"), in(A), in(A), set(), 0), v(0, 0, 0, 0)));
        check("a3 an auto app without code does not count", () -> expect(
                run(Arrays.asList(A + "\tauto"), NONE, NONE, set(), 0), v(0, 0, 0, 0)));
        check("b1 an ondemand app we installed counts as ours", () -> expect(
                run(Arrays.asList(O + "\tondemand"), in(O), NONE, set(O), 0), v(0, 1, 1, 0)));
        check("b2 an ondemand app not in materialised is not ours", () -> expect(
                run(Arrays.asList(O + "\tondemand"), in(O), NONE, set(B), 0), v(0, 1, 0, 0)));
        check("b3 a restored ondemand app does not count", () -> expect(
                run(Arrays.asList(O + "\tondemand"), in(O), in(O), set(O), 0), v(0, 0, 0, 0)));
        check("c1 a bare line counts nowhere", () -> expect(
                run(Arrays.asList(A), in(A), NONE, set(A), 0), v(0, 0, 0, 0)));
        check("c2 an installed line counts nowhere", () -> expect(
                run(Arrays.asList(A + "\tinstalled"), in(A), NONE, set(A), 0), v(0, 0, 0, 0)));
        check("d1 a group token keeps the ondemand mode", () -> expect(
                run(Arrays.asList(O + "\tondemand\tgroup:x"), in(O), NONE, set(), 0), v(0, 1, 0, 0)));
        check("d2 a group token keeps the auto mode", () -> expect(
                run(Arrays.asList(A + "\tauto\tgroup:x"), in(A), NONE, set(), 0), v(1, 0, 0, 0)));
        check("e1 a duplicate line counts once", () -> expect(
                run(Arrays.asList(O + "\tondemand", O + "\tondemand", "  " + O + "\tondemand  "),
                        in(O), NONE, set(O), 0), v(0, 1, 1, 0)));
        check("f1 restored is never read for an app without code", () -> expect(
                run(Arrays.asList(A + "\tauto", O + "\tondemand"), NONE,
                        p -> { throw new IllegalStateException("restored read for " + p); }, set(O), 0),
                v(0, 0, 0, 0)));
        check("g1 notready is passed through", () -> expect(
                run(Collections.<String>emptyList(), NONE, NONE, set(), 7), v(0, 0, 0, 7)));
        check("h1 the value names no package", () -> expect(
                run(Arrays.asList(A + "\tauto", B + "\tauto\tgroup:y", O + "\tondemand", N + "\tondemand", N,
                        B + "\tinstalled"), in(A, B, O), in(B), set(O, N), 3), v(1, 1, 1, 3)));
        check("i1 a blank or whitespace line is skipped", () -> expect(
                run(Arrays.asList("", "   ", "\t"), p -> true, NONE, set(), 0), v(0, 0, 0, 0)));
        check("i2 an empty package field is skipped", () -> expect(
                run(Arrays.asList(" \tondemand", "\tauto"), p -> true, NONE, set(""), 0), v(0, 0, 0, 0)));
        check("i3 no keep-set and no materialised set are zeros", () -> expect(
                run(null, p -> true, NONE, null, 0), v(0, 0, 0, 0)));
        System.exit(bad);
    }
}
