package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

/** NWP-20261117-15: the GET-MEDIA-STATUS routing; NWP-20261202-28: the RESTORING slot, its parser, its bar and the
 *  decided title. Exit 0 when every case holds, 1 otherwise. */
public final class MediaStatusCases {
    private static int bad = 0;

    private static void check(String label, List<String> lines, String wantLoading, String wantDamaged,
                              String wantIncomplete, String wantRestoring) {
        String[] got = MediaStatus.route(lines);
        String[] want = {wantLoading, wantDamaged, wantIncomplete, wantRestoring};
        if (got == null || got.length != 4 || !Objects.equals(got[0], want[0]) || !Objects.equals(got[1], want[1])
                || !Objects.equals(got[2], want[2]) || !Objects.equals(got[3], want[3])) {
            System.out.println("  FAIL  " + label + ": route(" + lines + ") = " + Arrays.toString(got) + ", want "
                    + Arrays.toString(want));
            bad++;
        } else {
            System.out.println("  ok    " + label);
        }
    }

    private static void checkRest(String label, String line, long[] want) {
        long[] got = MediaStatus.restoring(line);
        if (!Arrays.equals(got, want)) {
            System.out.println("  FAIL  " + label + ": restoring(" + line + ") = " + Arrays.toString(got) + ", want "
                    + Arrays.toString(want));
            bad++;
        } else {
            System.out.println("  ok    " + label);
        }
    }

    private static void checkBar(String label, long done, long total, int want) {
        int got = MediaStatus.restoringPermille(done, total);
        if (got != want) {
            System.out.println("  FAIL  " + label + ": restoringPermille(" + done + ", " + total + ") = " + got
                    + ", want " + want);
            bad++;
        } else {
            System.out.println("  ok    " + label);
        }
    }

    public static void main(String[] args) {
        String load = "LOADING 10 100 2 China_Guangxi.mwm";
        String dmg = "DAMAGED 1 Spain.mwm";
        String inc = "INCOMPLETE 1 com.example.game";
        // S1: mediad's three lines at once -- each kind gets its own line.
        check("S1 LOADING, DAMAGED and INCOMPLETE all route", Arrays.asList(load, dmg, inc), load, dmg, inc, null);
        // S2: the fetches ended -- DAMAGED is the first line, INCOMPLETE must still be read.
        check("S2 DAMAGED and INCOMPLETE with no LOADING", Arrays.asList("DAMAGED 2 Spain.mwm", inc),
                null, "DAMAGED 2 Spain.mwm", inc, null);
        // S3: the order does not matter.
        check("S3 INCOMPLETE before DAMAGED", Arrays.asList(inc, dmg), null, dmg, inc, null);
        // S4-S6: nothing to route.
        check("S4 IDLE alone", Collections.singletonList("IDLE"), null, null, null, null);
        check("S5 empty list", Collections.<String>emptyList(), null, null, null, null);
        check("S6 null list", null, null, null, null, null);
        // S7: the name is the tail field and may hold spaces; the line is kept whole, trimmed.
        check("S7 lone LOADING keeps its spaced name", Collections.singletonList("  LOADING 5 9 1 My Map File.mwm  "),
                "LOADING 5 9 1 My Map File.mwm", null, null, null);
        // S8: of two lines of one kind, the first is kept.
        check("S8 first of two LOADING lines", Arrays.asList("LOADING 1 2 1 a.mwm", "LOADING 3 4 1 b.mwm"),
                "LOADING 1 2 1 a.mwm", null, null, null);
        // S9: unknown, blank and null lines are ignored.
        check("S9 unknown, blank and null lines ignored", Arrays.asList("WHATEVER x", "", null, dmg),
                null, dmg, null, null);
        // S10-S13 (NWP-20261202-28): the after-gate restore's RESTORING line gets the fourth slot.
        String rest = "RESTORING 10 100 3";
        check("S10 RESTORING beside LOADING, DAMAGED and INCOMPLETE", Arrays.asList(load, dmg, inc, rest),
                load, dmg, inc, rest);
        check("S11 RESTORING before LOADING", Arrays.asList(rest, inc, load), load, null, inc, rest);
        check("S12 first of two RESTORING lines", Arrays.asList(rest, "RESTORING 50 100 1"), null, null, null, rest);
        check("S13 lone padded RESTORING", Collections.singletonList("  RESTORING 0 7 2  "),
                null, null, null, "RESTORING 0 7 2");
        // P1-P10: restoring() takes three non-negative integers, left > 0 and done <= total; anything else is null.
        checkRest("P1 good line", rest, new long[] {10, 100, 3});
        checkRest("P2 done == total, one file left", "RESTORING 100 100 1", new long[] {100, 100, 1});
        checkRest("P3 left 0", "RESTORING 10 100 0", null);
        checkRest("P4 done > total", "RESTORING 101 100 3", null);
        checkRest("P5 negative", "RESTORING -1 100 3", null);
        checkRest("P6 non-number", "RESTORING 10 x 3", null);
        checkRest("P7 missing field", "RESTORING 10 100", null);
        checkRest("P8 extra field", "RESTORING 10 100 3 a.jpg", null);
        checkRest("P9 null", null, null);
        checkRest("P10 another kind", "LOADING 10 100 3", null);
        // Q1-Q5: restoringPermille() is the determinate 0-1000 bar; a total of 0 is a known size, so 0, never < 0.
        checkBar("Q1 a tenth", 10, 100, 100);
        checkBar("Q2 zero-byte set (RESTORING 0 0 1)", 0, 0, 0);
        checkBar("Q3 done == total", 100, 100, 1000);
        checkBar("Q4 none done", 0, 7, 0);
        checkBar("Q5 huge counts do not overflow", 40_000_000_000_000_000L, 100_000_000_000_000_000L, 400);
        // T1: the decided O3 words (docs/product-decisions.md, 2026-11-02).
        if (!"Restoring photos and files".equals(MediaStatus.RESTORING_TITLE)) {
            System.out.println("  FAIL  T1 RESTORING_TITLE = " + MediaStatus.RESTORING_TITLE);
            bad++;
        } else {
            System.out.println("  ok    T1 RESTORING_TITLE is the decided O3 words");
        }
        if (bad != 0) {
            System.out.println(bad + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases ok");
    }
}
