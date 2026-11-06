package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

/** NWP-20261117-15: the GET-MEDIA-STATUS routing. Exit 0 when every case holds, 1 otherwise. */
public final class MediaStatusCases {
    private static int bad = 0;

    private static void check(String label, List<String> lines, String wantLoading, String wantDamaged,
                              String wantIncomplete) {
        String[] got = MediaStatus.route(lines);
        String[] want = {wantLoading, wantDamaged, wantIncomplete};
        if (got == null || got.length != 3 || !Objects.equals(got[0], want[0]) || !Objects.equals(got[1], want[1])
                || !Objects.equals(got[2], want[2])) {
            System.out.println("  FAIL  " + label + ": route(" + lines + ") = " + Arrays.toString(got) + ", want "
                    + Arrays.toString(want));
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
        check("S1 LOADING, DAMAGED and INCOMPLETE all route", Arrays.asList(load, dmg, inc), load, dmg, inc);
        // S2: the fetches ended -- DAMAGED is the first line, INCOMPLETE must still be read.
        check("S2 DAMAGED and INCOMPLETE with no LOADING", Arrays.asList("DAMAGED 2 Spain.mwm", inc),
                null, "DAMAGED 2 Spain.mwm", inc);
        // S3: the order does not matter.
        check("S3 INCOMPLETE before DAMAGED", Arrays.asList(inc, dmg), null, dmg, inc);
        // S4-S6: nothing to route.
        check("S4 IDLE alone", Collections.singletonList("IDLE"), null, null, null);
        check("S5 empty list", Collections.<String>emptyList(), null, null, null);
        check("S6 null list", null, null, null, null);
        // S7: the name is the tail field and may hold spaces; the line is kept whole, trimmed.
        check("S7 lone LOADING keeps its spaced name", Collections.singletonList("  LOADING 5 9 1 My Map File.mwm  "),
                "LOADING 5 9 1 My Map File.mwm", null, null);
        // S8: of two lines of one kind, the first is kept.
        check("S8 first of two LOADING lines", Arrays.asList("LOADING 1 2 1 a.mwm", "LOADING 3 4 1 b.mwm"),
                "LOADING 1 2 1 a.mwm", null, null);
        // S9: unknown, blank and null lines are ignored.
        check("S9 unknown, blank and null lines ignored", Arrays.asList("WHATEVER x", "", null, dmg), null, dmg, null);
        if (bad != 0) {
            System.out.println(bad + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases ok");
    }
}
