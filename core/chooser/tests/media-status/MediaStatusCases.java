package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

/** NWP-20261117-15: the GET-MEDIA-STATUS routing; NWP-20261202-28: the RESTORING slot, its parser, its bar and the
 *  decided title; NWP-20261207-11: the RESTORE-WAITING slot, restoreWaiting() and the decided waiting body. Exit 0
 *  when every case holds, 1 otherwise. */
public final class MediaStatusCases {
    private static int bad = 0;

    private static void check(String label, List<String> lines, String wantLoading, String wantDamaged,
                              String wantIncomplete, String wantRestoring) {
        String[] got = MediaStatus.route(lines);
        String[] want = {wantLoading, wantDamaged, wantIncomplete, wantRestoring};
        if (got == null || got.length != 5 || !Objects.equals(got[0], want[0]) || !Objects.equals(got[1], want[1])
                || !Objects.equals(got[2], want[2]) || !Objects.equals(got[3], want[3]) || got[4] != null) {
            System.out.println("  FAIL  " + label + ": route(" + lines + ") = " + Arrays.toString(got) + ", want "
                    + Arrays.toString(want));
            bad++;
        } else {
            System.out.println("  ok    " + label);
        }
    }

    /** NWP-20261207-11: route's slots 3 (restoring) and 4 (waiting). */
    private static void checkWait(String label, List<String> lines, String wantRestoring, String wantWaiting) {
        String[] got = MediaStatus.route(lines);
        if (got == null || got.length != 5 || !Objects.equals(got[3], wantRestoring)
                || !Objects.equals(got[4], wantWaiting)) {
            System.out.println("  FAIL  " + label + ": route(" + lines + ") = " + Arrays.toString(got) + ", want slot 3 "
                    + wantRestoring + ", slot 4 " + wantWaiting);
            bad++;
        } else {
            System.out.println("  ok    " + label);
        }
    }

    private static void checkRW(String label, String[] routed, boolean want) {
        boolean got = MediaStatus.restoreWaiting(routed);
        if (got != want) {
            System.out.println("  FAIL  " + label + ": restoreWaiting(" + Arrays.toString(routed) + ") = " + got
                    + ", want " + want);
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

    private static void checkLanded(String label, String reply, String want) {
        String got = MediaStatus.landed(reply);
        if (want == null ? got != null : !want.equals(got)) {
            System.out.println("  FAIL  " + label + ": landed(" + reply + ") = " + got + ", want " + want);
            bad++;
        } else {
            System.out.println("  ok    " + label);
        }
    }

    private static void checkRescan(String label, String seen, String reply, boolean want) {
        boolean got = MediaStatus.rescanAfterLanding(seen, reply);
        if (got != want) {
            System.out.println("  FAIL  " + label + ": rescanAfterLanding(" + seen + ", " + reply + ") = " + got
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
        // W1-W6 (NWP-20261207-11): RESTORE-WAITING fills slot 4 by exact match only, and restoreWaiting() needs a
        // valid RESTORING line beside it.
        String rw = "RESTORE-WAITING";
        checkWait("W1 RESTORING then RESTORE-WAITING", Arrays.asList(rest, rw), rest, rw);
        checkRW("W1 restoreWaiting with both lines", MediaStatus.route(Arrays.asList(rest, rw)), true);
        checkWait("W2 padded RESTORE-WAITING before RESTORING", Arrays.asList("  RESTORE-WAITING  ", rest), rest, rw);
        checkWait("W3 RESTORE-WAITINGX fills no slot", Arrays.asList(rest, "RESTORE-WAITINGX"), rest, null);
        checkWait("W4 RESTORING-WAIT never fills slot 4", Arrays.asList(rest, "RESTORING-WAIT"), rest, null);
        checkRW("W5a a lone RESTORE-WAITING is not a restore", MediaStatus.route(Collections.singletonList(rw)), false);
        checkRW("W5b RESTORING with left 0", MediaStatus.route(Arrays.asList("RESTORING 1 2 0", rw)), false);
        checkRW("W5c RESTORING with done > total", MediaStatus.route(Arrays.asList("RESTORING 5 2 1", rw)), false);
        checkRW("W5d null", null, false);
        checkRW("W5e four slots", new String[] {null, null, null, rest}, false);
        checkRW("W6 RESTORING with no waiting line", MediaStatus.route(Collections.singletonList(rest)), false);
        // T2: the decided O3 words for the parked restore (docs/product-decisions.md, 2026-11-02).
        if (!"Waiting for a network".equals(MediaStatus.WAITING_BODY)) {
            System.out.println("  FAIL  T2 WAITING_BODY = " + MediaStatus.WAITING_BODY);
            bad++;
        } else {
            System.out.println("  ok    T2 WAITING_BODY is the decided O3 words");
        }
        // L1-L11 (NWP-20261114-34): landed() reads a GET-MEDIA-LANDED reply as a count; rescanAfterLanding() decides
        // whether the gate starts the session's rescan, given the count it last saw.
        checkLanded("L1 a count", "3", "3");
        checkLanded("L2 trailing newline and spaces", " 12\n", "12");
        checkLanded("L3 leading zeros are one count", "007", "7");
        checkLanded("L4 empty read", "", null);
        checkLanded("L5 null read", null, null);
        checkLanded("L6 not a number", "IDLE", null);
        checkLanded("L7 negative", "-1", null);
        checkRescan("L8 a first landing in the session", "0", "1", true);
        checkRescan("L9 the same count again", "1", "1", false);
        checkRescan("L10 a mediad restart (count back to 0)", "3", "0", false);
        checkRescan("L11 the restarted mediad lands (1 after 3)", "3", "1", true);
        checkRescan("L12 a failed read changes nothing", "2", "", false);
        checkRescan("L13 a second landing", "1", "2", true);
        if (bad != 0) {
            System.out.println(bad + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases ok");
    }
}
