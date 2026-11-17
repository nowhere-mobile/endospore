package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** NWP-20261204-10: test-mms-ingest-plan-java.sh compiles this with MmsIngestPlan.java, ALONE, and runs it. Prints one
 *  ok or FAIL line per case; exits 1 when any case failed. */
public final class MmsIngestPlanCases {
    static boolean failed = false;

    static void eq(String id, String what, Object want, Object got) {
        if (want.equals(got)) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        failed = true;
    }

    static void report(String id) {
        if (!failed) System.out.println("ok " + id);
    }

    static boolean t(String... cts) { return MmsIngestPlan.textOnly(Arrays.asList(cts)); }

    public static void main(String[] a) {
        boolean bad = false;

        // C1: textOnly is 1 or 2 parts, each smil or text/plain, at least one text/plain.
        eq("C1", "[smil, text/plain;charset=utf-8]", true, t("application/smil", "text/plain;charset=utf-8"));
        eq("C1", "[text/plain]", true, t("text/plain"));
        eq("C1", "[text/plain, text/plain]", true, t("text/plain", "text/plain"));
        eq("C1", "[smil]", false, t("application/smil"));
        eq("C1", "[image/jpeg, text/plain]", false, t("image/jpeg", "text/plain"));
        eq("C1", "[smil, text/plain, text/plain]", false, t("application/smil", "text/plain", "text/plain"));
        eq("C1", "[text/x-vCard]", false, t("text/x-vCard"));
        List<String> none = Collections.emptyList();
        eq("C1", "[]", false, MmsIngestPlan.textOnly(none));
        report("C1"); bad |= failed; failed = false;

        // C2: the hint is today's condition: a note, no non-empty text, no media.
        eq("C2", "too-large, no text, no media", true, MmsIngestPlan.hint("too-large", false, false));
        eq("C2", "too-large with a non-empty text", false, MmsIngestPlan.hint("too-large", true, false));
        eq("C2", "too-large with media", false, MmsIngestPlan.hint("too-large", false, true));
        eq("C2", "an empty note", false, MmsIngestPlan.hint("", false, false));
        report("C2"); bad |= failed; failed = false;

        // C3: the placeholder is the arrival itself, above 0 for a real arrival.
        long when = 1767225600123L;
        eq("C3", "placeholderMid(when)", when, MmsIngestPlan.placeholderMid(when));
        eq("C3", "placeholderMid(when) > 0", true, MmsIngestPlan.placeholderMid(when) > 0);
        report("C3"); bad |= failed;

        System.exit(bad ? 1 : 0);
    }
}
