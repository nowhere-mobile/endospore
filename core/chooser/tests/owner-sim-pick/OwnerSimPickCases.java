package com.nowhere.chooser;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/** Cases for OwnerSimPick (NWP-20261111-20). An exception in a case is a FAIL, not a crash. The carrier names are
 *  test values, not a real network's. */
public final class OwnerSimPickCases {
    private static int failed = 0, ran = 0;

    private static void check(String name, boolean cond) {
        ran++;
        if (!cond) { failed++; System.out.println("--- FAIL " + name); }
    }

    private static void eq(String name, int want, int got) { check(name + " (want " + want + ", got " + got + ")", want == got); }

    private static void eq(String name, String want, String got) {
        check(name + " (want \"" + want + "\", got " + (got == null ? "null" : "\"" + got + "\"") + ")", want.equals(got));
    }

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

    private static void run() throws Exception {
        // P1: initial(count, arrival). The arrival wins inside the list; one SIM is the only choice; two or more
        // with no known arrival choose nothing; an empty list chooses nothing.
        final int[][] table = {
            // count, arrival -1, arrival 0, arrival 1
            { 0, -1, -1, -1 },
            { 1,  0,  0,  0 },
            { 2, -1,  0,  1 },
            { 3, -1,  0,  1 },
        };
        for (int[] r : table)
            for (int a = -1; a <= 1; a++)
                eq("P1 initial(" + r[0] + ", " + a + ")", r[a + 2], OwnerSimPick.initial(r[0], a));

        // P2: rowLabel names the carrier and the slot, so two SIMs of one carrier differ.
        eq("P2 rowLabel slot 0", "Carrier A — SIM 1", OwnerSimPick.rowLabel("Carrier A", 0));
        eq("P2 rowLabel slot 1", "Carrier A — SIM 2", OwnerSimPick.rowLabel("Carrier A", 1));
        eq("P2 rowLabel slot -1", "Carrier A", OwnerSimPick.rowLabel("Carrier A", -1));
        check("P2 one carrier in two slots gives two labels",
                !OwnerSimPick.rowLabel("Carrier A", 0).equals(OwnerSimPick.rowLabel("Carrier A", 1)));
        // P3: activeSims' fallback name "SIM <slot+1>" is not doubled; no carrier name still names the slot.
        eq("P3 rowLabel fallback name", "SIM 2", OwnerSimPick.rowLabel("SIM 2", 1));
        eq("P3 rowLabel null carrier", "SIM 1", OwnerSimPick.rowLabel(null, 0));
        eq("P3 rowLabel blank carrier, no slot", "SIM", OwnerSimPick.rowLabel("", -1));

        // P4: rowLabel takes a carrier and a slot only -- no ICCID, no number.
        final List<Method> labels = new ArrayList<>();
        for (Method m : OwnerSimPick.class.getDeclaredMethods()) if (m.getName().equals("rowLabel")) labels.add(m);
        check("P4 exactly one rowLabel (got " + labels.size() + ")", labels.size() == 1);
        if (labels.size() == 1) {
            final Class<?>[] p = labels.get(0).getParameterTypes();
            check("P4 rowLabel(String, int)", p.length == 2 && p[0] == String.class && p[1] == int.class);
        }
    }
}
