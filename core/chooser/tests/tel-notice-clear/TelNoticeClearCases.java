package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.HashSet;
import java.util.Set;

/** Cases for TelNoticeClear (NWP-20261110-22). Prints PASS/FAIL per case; exit 1 when any failed. */
public final class TelNoticeClearCases {
    private static int bad = 0;

    private interface Body { void run() throws Throwable; }

    private static void c(String name, Body b) {
        try { b.run(); } catch (Throwable e) { bad++; System.out.println("FAIL " + name + ": threw " + e); }
    }

    private static void eq(String name, String got, String want) {
        if (want.equals(got)) { System.out.println("PASS " + name); return; }
        bad++; System.out.println("FAIL " + name + ": got [" + got + "] want [" + want + "]");
    }

    private static void set(String name, Set<String> got, Set<String> want) {
        if (got != null && got.equals(want)) { System.out.println("PASS " + name); return; }
        bad++; System.out.println("FAIL " + name + ": got " + got + " want " + want);
    }

    private static Set<String> of(String... v) {
        Set<String> s = new HashSet<>();
        for (String x : v) s.add(x);
        return s;
    }

    private static String b64(String s) {
        return "L" + Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }

    public static void main(String[] a) {
        c("L1 labelOf after the separator", () -> eq("L1 labelOf after the separator",
                TelNoticeClear.labelOf("New message  -  Work"), "Work"));
        c("L1 labelOf bare title", () -> eq("L1 labelOf bare title", TelNoticeClear.labelOf("Missed call"), ""));
        c("L1 labelOf null", () -> eq("L1 labelOf null", TelNoticeClear.labelOf(null), ""));
        c("L1 labelOf empty label", () -> eq("L1 labelOf empty label", TelNoticeClear.labelOf("New message  -  "), ""));
        c("L1 labelOf splits on the first separator", () -> eq("L1 labelOf splits on the first separator",
                TelNoticeClear.labelOf("3 new messages  -  a  -  b"), "a  -  b"));

        c("U1 null", () -> set("U1 null", TelNoticeClear.unboundLabels(null), of()));
        c("U1 empty", () -> set("U1 empty", TelNoticeClear.unboundLabels(""), of()));
        c("U1 OK", () -> set("U1 OK", TelNoticeClear.unboundLabels("OK"), of()));
        c("U1 NOTFOUND", () -> set("U1 NOTFOUND", TelNoticeClear.unboundLabels("NOTFOUND"), of()));
        c("U1 ERR", () -> set("U1 ERR", TelNoticeClear.unboundLabels("ERR damaged"), of()));
        c("U2 blank label", () -> set("U2 blank label", TelNoticeClear.unboundLabels("OK L"), of("")));
        c("U3 two labels", () -> set("U3 two labels",
                TelNoticeClear.unboundLabels("OK " + b64("Work") + " " + b64("Büro")), of("Work", "Büro")));
        c("U4 strangers skipped", () -> set("U4 strangers skipped",
                TelNoticeClear.unboundLabels("OK " + b64("Work") + " Xabc L!!! " + b64("Büro")),
                of("Work", "Büro")));
        c("U5 first token never decoded", () -> set("U5 first token never decoded",
                TelNoticeClear.unboundLabels("LV29yaw== LQQ=="), of("A")));
        System.exit(bad == 0 ? 0 : 1);
    }
}
