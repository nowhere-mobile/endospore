package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** Cases for AbsentSims (NWP-20261116-20). An exception in a case is a FAIL, not a crash. The ICCIDs are test
 *  values, not a real SIM's. */
public final class AbsentSimsCases {
    private static int failed = 0, ran = 0;

    private static void check(String name, boolean cond) {
        ran++;
        if (!cond) { failed++; System.out.println("--- FAIL " + name); }
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

    private static final String A = "8901260000000001234";
    private static final String B = "8901260000000005678";
    private static final String C = "8901260000000009999";

    // A good bindingSummaries entry: {subId, iccid, "<n> bound · <vis>", label, vis}.
    private static String[] e(String sub, String icc, String sum) { return new String[]{ sub, icc, sum, "", "open" }; }

    private static List<String[]> sums(String[]... es) { return new ArrayList<>(Arrays.asList(es)); }
    private static List<String> iccs(String... a) { return Arrays.asList(a); }
    private static List<Integer> ids(Integer... a) { return Arrays.asList(a); }
    private static final List<String> NO_ICCS = Collections.emptyList();
    private static final List<Integer> NO_IDS = Collections.emptyList();

    private static void run() {
        // A1: an absent ICCID is listed, and its summary shows the last four digits.
        String[] a1 = e("3", A + "F", "2 bound · open");
        List<String[]> r1 = AbsentSims.rows(sums(a1), iccs(C), NO_IDS);
        check("A1 an absent ICCID is listed", r1.size() == 1 && r1.get(0) == a1);
        check("A1 summary", "ends 1234 · 2 bound · open".equals(AbsentSims.summary(a1)));
        check("A1 summary, no trailing F", "ends 1234 · 1 bound · private".equals(AbsentSims.summary(e("3", A, "1 bound · private"))));

        // A2: a present ICCID is not listed, also when only one side carries the trailing F.
        check("A2 present, same text", AbsentSims.rows(sums(e("3", A, "1 bound · open")), iccs(A), NO_IDS).isEmpty());
        check("A2 present, stored side ends in F", AbsentSims.rows(sums(e("3", A + "F", "1 bound · open")), iccs(A), NO_IDS).isEmpty());
        check("A2 present, active side ends in F", AbsentSims.rows(sums(e("3", A, "1 bound · open")), iccs(A + "F"), NO_IDS).isEmpty());

        // A3: an entry whose subId belongs to an active SIM read with no ICCID is not listed; another subId is.
        check("A3 subId of an active SIM without ICCID", AbsentSims.rows(sums(e("7", A, "1 bound · open")), NO_ICCS, ids(7)).isEmpty());
        check("A3 another subId is listed", AbsentSims.rows(sums(e("7", A, "1 bound · open")), NO_ICCS, ids(8)).size() == 1);

        // A4: an entry with an empty ICCID is not listed.
        check("A4 empty ICCID", AbsentSims.rows(sums(e("3", "", "1 bound · open")), NO_ICCS, NO_IDS).isEmpty());
        check("A4 spaces-only ICCID", AbsentSims.rows(sums(e("3", "  ", "1 bound · open")), NO_ICCS, NO_IDS).isEmpty());

        // A5: TelArrival.DAMAGED_ROW ({"", "", ""}) is skipped; the good entry beside it is listed.
        String[] a5 = e("4", B, "1 bound · open");
        List<String[]> r5 = AbsentSims.rows(sums(new String[]{ "", "", "" }, a5), NO_ICCS, NO_IDS);
        check("A5 DAMAGED_ROW skipped", r5.size() == 1 && r5.get(0) == a5);

        // A6: null sums give an empty, non-null list.
        List<String[]> r6 = AbsentSims.rows(null, NO_ICCS, NO_IDS);
        check("A6 null sums", r6 != null && r6.isEmpty());

        // A7: a duplicate ICCID is listed once, the first entry kept (padded vs unpadded too).
        String[] a7a = e("3", A + "F", "1 bound · open"), a7b = e("5", A, "2 bound · private");
        List<String[]> r7 = AbsentSims.rows(sums(a7a, a7b), NO_ICCS, NO_IDS);
        check("A7 duplicate listed once", r7.size() == 1 && r7.get(0) == a7a);

        // A8: order is kept.
        String[] x = e("1", C, "1 bound · open"), y = e("2", A, "1 bound · open"), z = e("3", B, "1 bound · open");
        List<String[]> r8 = AbsentSims.rows(sums(x, y, z), NO_ICCS, NO_IDS);
        check("A8 order kept", r8.size() == 3 && r8.get(0) == x && r8.get(1) == y && r8.get(2) == z);

        // A9: the row title.
        check("A9 TITLE", "SIM not in this phone".equals(AbsentSims.TITLE));
    }
}
