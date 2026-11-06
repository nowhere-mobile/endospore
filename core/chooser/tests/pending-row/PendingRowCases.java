package com.nowhere.chooser;

/** NWP-20261027-12: the decision the Your apps screen takes about its "Install pending apps now" row.
 *  NWP-20261119-30: and the three-argument form, which rebuilds an unchanged row at a sweep's end. */
public final class PendingRowCases {
    private static int bad = 0;

    private static void check(int shown, int n, int want, String name) {
        int got = PendingRow.action(shown, n);
        if (got == want) {
            System.out.println("ok   action(" + shown + "," + n + ") = " + name);
        } else {
            System.out.println("FAIL action(" + shown + "," + n + ") = " + got + ", want " + name);
            bad++;
        }
    }

    private static void check3(int shown, int n, boolean ended, int want, String name) {
        int got = PendingRow.action(shown, n, ended);
        if (got == want) {
            System.out.println("ok   action(" + shown + "," + n + "," + ended + ") = " + name);
        } else {
            System.out.println("FAIL action(" + shown + "," + n + "," + ended + ") = " + got + ", want " + name);
            bad++;
        }
    }

    public static void main(String[] args) {
        if (PendingRow.NONE != 0 || PendingRow.ADD != 1 || PendingRow.REPLACE != 2 || PendingRow.REMOVE != 3) {
            System.out.println("FAIL the four action constants are not 0, 1, 2, 3");
            bad++;
        }
        check(0, 0, PendingRow.NONE, "NONE");
        check(0, 2, PendingRow.ADD, "ADD");
        check(2, 2, PendingRow.NONE, "NONE");
        check(2, 3, PendingRow.REPLACE, "REPLACE");
        check(3, 0, PendingRow.REMOVE, "REMOVE");
        check(-1, 2, PendingRow.ADD, "ADD");
        check(2, -1, PendingRow.REMOVE, "REMOVE");
        // NWP-20261119-30: a sweep ended and left apps pending: the row is rebuilt even at an unchanged count
        for (int n = 1; n <= 4; n++) check3(n, n, true, PendingRow.REPLACE, "REPLACE");
        check3(0, 0, true, PendingRow.NONE, "NONE");
        check3(3, 0, true, PendingRow.REMOVE, "REMOVE");
        check3(0, 2, true, PendingRow.ADD, "ADD");
        int grid = 0;                                           // false is today's answer, for every input
        for (int s = 0; s <= 4; s++) {
            for (int n = 0; n <= 4; n++) {
                if (PendingRow.action(s, n, false) != PendingRow.action(s, n)) {
                    System.out.println("FAIL action(" + s + "," + n + ",false) != action(" + s + "," + n + ")");
                    grid++;
                }
            }
        }
        if (grid == 0) System.out.println("ok   action(s,n,false) == action(s,n) for s, n in 0..4");
        bad += grid;
        if (bad != 0) {
            System.out.println(bad + " case(s) failed");
            System.exit(1);
        }
        System.out.println("suite passed");
    }
}
