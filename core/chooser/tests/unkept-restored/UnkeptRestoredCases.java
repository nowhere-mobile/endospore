package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.function.Predicate;

/** NWP-20261203-24: the cases for UnkeptRestored.select. Each prints "ok <name>" or "FAIL <name>"; exit 1 on any
 *  FAIL. A case lets exactly one filter drop its package, so a mutant that removes that filter fails that case. */
public final class UnkeptRestoredCases {
    private static int fails = 0;
    private static final String OWN = "com.nowhere.chooser";
    private static final Set<String> NONE = Collections.emptySet();
    private static final Predicate<String> NOT_BUNDLED = p -> false;
    private static final Predicate<String> INSTALLED = p -> true;

    private static void check(String name, LinkedHashSet<String> got, List<String> want) {
        if (new java.util.ArrayList<>(got).equals(want)) System.out.println("ok   " + name);
        else { System.out.println("FAIL " + name + ": got " + got + ", want " + want); fails++; }
    }

    private static LinkedHashSet<String> sel(List<String> lines, Set<String> kept, Set<String> orphans,
            Predicate<String> bundled, Predicate<String> installed) {
        return UnkeptRestored.select(lines, kept, orphans, OWN, bundled, installed);
    }

    private static Set<String> set(String... s) { return new HashSet<>(Arrays.asList(s)); }

    public static void main(String[] args) {
        check("C1 a restored, unkept, installed app is selected",
                sel(Arrays.asList("org.example.notes"), NONE, NONE, NOT_BUNDLED, INSTALLED),
                Arrays.asList("org.example.notes"));
        // the keep-set's keys hold every mode: installed, ondemand and auto are all kept
        check("C2 an app kept in any mode is not selected",
                sel(Arrays.asList("org.example.inst", "org.example.od", "org.example.auto", "org.example.off"),
                        set("org.example.inst", "org.example.od", "org.example.auto"), NONE, NOT_BUNDLED, INSTALLED),
                Arrays.asList("org.example.off"));
        check("C3 an inferred orphan is not selected",
                sel(Arrays.asList("org.example.dep", "org.example.off"), NONE, set("org.example.dep"),
                        NOT_BUNDLED, INSTALLED),
                Arrays.asList("org.example.off"));
        check("C4 the Play stack (vending, gms, gsf) is not selected",
                sel(Arrays.asList("com.android.vending", "com.google.android.gms", "com.google.android.gsf",
                        "org.example.off"), NONE, NONE, NOT_BUNDLED, INSTALLED),
                Arrays.asList("org.example.off"));
        check("C5 the chooser's own package is not selected",
                sel(Arrays.asList(OWN, "org.example.off"), NONE, NONE, NOT_BUNDLED, INSTALLED),
                Arrays.asList("org.example.off"));
        check("C6 a bundled app is not selected",
                sel(Arrays.asList("org.example.system", "org.example.off"), NONE, NONE,
                        p -> p.equals("org.example.system"), INSTALLED),
                Arrays.asList("org.example.off"));
        check("C7 an app that is not installed any more is not selected",
                sel(Arrays.asList("org.example.gone", "org.example.off"), NONE, NONE, NOT_BUNDLED,
                        p -> !p.equals("org.example.gone")),
                Arrays.asList("org.example.off"));
        check("C8 blank lines are skipped, a padded line is trimmed and a duplicate is selected once",
                sel(Arrays.asList("", "   ", "  org.example.off  ", "org.example.off", "\torg.example.off", null),
                        NONE, NONE, NOT_BUNDLED, INSTALLED),
                Arrays.asList("org.example.off"));
        check("C9 the input order is kept",
                sel(Arrays.asList("org.example.c", "org.example.a", "org.example.b"), NONE, NONE, NOT_BUNDLED,
                        INSTALLED),
                Arrays.asList("org.example.c", "org.example.a", "org.example.b"));
        check("C10 no restored line selects nothing",
                sel(Collections.<String>emptyList(), NONE, NONE, NOT_BUNDLED, INSTALLED),
                Collections.<String>emptyList());
        System.exit(fails == 0 ? 0 : 1);
    }
}
