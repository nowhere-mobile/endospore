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

        // NWP-20261128-18: the kind a gate notice stands for. The nowhere_call extra wins over the title; a notice
        // posted before that extra is read by its title, before the "  -  <label>" suffix.
        c("K1 an answered call by its extra", () -> eq("K1 an answered call by its extra",
                TelNoticeClear.kindOf("call", "incoming", "Missed call  -  Sim1"), "incoming"));
        c("K2 a missed call by its extra", () -> eq("K2 a missed call by its extra",
                TelNoticeClear.kindOf("call", "missed", "Incoming call  -  Sim1"), "call"));
        c("K3 an older answered call by its title", () -> eq("K3 an older answered call by its title",
                TelNoticeClear.kindOf("call", "", "Incoming call  -  Sim1"), "incoming"));
        c("K4 an older count of answered calls by its title", () -> eq("K4 an older count of answered calls by its title",
                TelNoticeClear.kindOf("call", "", "2 incoming calls  -  Sim1"), "incoming"));
        c("K5 an older missed call by its title", () -> eq("K5 an older missed call by its title",
                TelNoticeClear.kindOf("call", "", "Missed call"), "call"));
        c("K6 a notice with no extras by its title", () -> eq("K6 a notice with no extras by its title",
                TelNoticeClear.kindOf("", "", "Incoming call"), "incoming"));
        c("K7 a message", () -> eq("K7 a message", TelNoticeClear.kindOf("message", "", "New message"), "message"));
        c("K8 the label cannot change the kind", () -> eq("K8 the label cannot change the kind",
                TelNoticeClear.kindOf("call", "", "2 missed calls  -  x incoming calls"), "call"));
        c("K9 null extras and title", () -> eq("K9 null extras and title", TelNoticeClear.kindOf(null, null, null), "message"));
        System.exit(bad == 0 ? 0 : 1);
    }
}
