package com.nowhere.chooser;

import java.util.Locale;

/** NWP-20261117-43: the time zone search and its row label. Exit 0 when every case holds, 1 otherwise. */
public final class ZoneSearchCases {
    private static int bad = 0;

    private static void check(String label, boolean ok, String detail) {
        if (!ok) {
            System.out.println("  FAIL  " + label + ": " + detail);
            bad++;
        } else {
            System.out.println("  ok    " + label);
        }
    }

    private static void match(String label, boolean want, String id, String q) {
        boolean got = ZoneSearch.matches(id, q);
        check(label, got == want, "matches(\"" + id + "\", \"" + q + "\") = " + got + ", want " + want);
    }

    private static void auto(String label, boolean want, String q) {
        boolean got = ZoneSearch.automaticMatches(q);
        check(label, got == want, "automaticMatches(\"" + q + "\") = " + got + ", want " + want);
    }

    private static void labelIs(String label, String id, int off, String want, boolean whole) {
        String got = ZoneSearch.label(id, off);
        boolean ok = whole ? got.equals(want) : got.endsWith(want);
        check(label, ok, "label(\"" + id + "\", " + off + ") = \"" + got + "\", want "
                + (whole ? "" : "a text ending ") + "\"" + want + "\"");
    }

    public static void main(String[] args) {
        // C1: a city typed as its row shows it (spaces), as its id spells it (underscores), or in part.
        match("C1 \"new york\" finds America/New_York", true, "America/New_York", "new york");
        match("C1 \"New_York\" finds America/New_York", true, "America/New_York", "New_York");
        match("C1 \"york\" finds America/New_York", true, "America/New_York", "york");
        match("C1 \"america/new\" finds America/New_York", true, "America/New_York", "america/new");
        match("C1 \"los angeles\" finds America/Los_Angeles", true, "America/Los_Angeles", "los angeles");
        match("C1 \"st johns\" finds America/St_Johns", true, "America/St_Johns", "st johns");
        match("C1 \"tokyo\" does not find Europe/London", false, "Europe/London", "tokyo");
        // C2: an empty query lists every zone.
        match("C2 \"\" finds America/New_York", true, "America/New_York", "");
        match("C2 \"\" finds Europe/London", true, "Europe/London", "");
        match("C2 \"\" finds Asia/Kolkata", true, "Asia/Kolkata", "");
        // C3: case folds the same in every locale (tr-TR lower-cases 'I' to a dotless i).
        Locale prev = Locale.getDefault();
        Locale.setDefault(Locale.forLanguageTag("tr-TR"));
        try {
            match("C3 tr-TR \"istanbul\" finds Europe/Istanbul", true, "Europe/Istanbul", "istanbul");
            match("C3 tr-TR \"ISTANBUL\" finds Europe/Istanbul", true, "Europe/Istanbul", "ISTANBUL");
        } finally {
            Locale.setDefault(prev);
        }
        // C4: the "Automatic" row.
        auto("C4 \"\" shows Automatic", true, "");
        auto("C4 \"auto\" shows Automatic", true, "auto");
        auto("C4 \"AUTOMATIC\" shows Automatic", true, "AUTOMATIC");
        auto("C4 \"new york\" hides Automatic", false, "new york");
        // C5: the row label, byte for byte, half-hour offsets included.
        labelIs("C5 New York label", "America/New_York", -300, "America/New York  (GMT-05:00)", true);
        labelIs("C5 St Johns half hour behind", "America/St_Johns", -210, "(GMT-03:30)", false);
        labelIs("C5 Kolkata half hour ahead", "Asia/Kolkata", 330, "(GMT+05:30)", false);
        labelIs("C5 London zero offset", "Europe/London", 0, "(GMT+00:00)", false);
        if (bad != 0) {
            System.out.println(bad + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases ok");
    }
}
