package com.nowhere.chooser;

/** NWP-20261120-03: BuildWarningNotice.due and its three strings, run by test-build-warning-notice-java.sh. */
public final class BuildWarningNoticeCases {
    private static int failed = 0;

    private static void check(boolean ok, String what) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) failed++;
    }

    public static void main(String[] args) {
        check(BuildWarningNotice.due("WARN", false, false, false), "WARN raises the notice");
        check(BuildWarningNotice.due(" WARN\n", false, false, false), "WARN with spaces and a newline raises it");
        check(!BuildWarningNotice.due("NONE", false, false, false), "NONE shows nothing");
        check(!BuildWarningNotice.due("", false, false, false), "an empty reply (no daemon, a timeout) shows nothing");
        check(!BuildWarningNotice.due(null, false, false, false), "a null reply shows nothing");
        check(!BuildWarningNotice.due("ERR unknown", false, false, false), "an error reply shows nothing");
        check(!BuildWarningNotice.due("WARNING", false, false, false), "a reply that only starts with WARN shows nothing");
        check(!BuildWarningNotice.due("warn", false, false, false), "a lower-case warn shows nothing");
        check(!BuildWarningNotice.due("WARN", true, false, false), "WARN while the notice is showing raises no second one");
        check(!BuildWarningNotice.due("WARN", false, true, false), "WARN after Continue, before a screen-off, shows nothing");
        check(!BuildWarningNotice.due("WARN", false, false, true), "WARN while the gate is finishing shows nothing");
        check("A known problem in this version".equals(BuildWarningNotice.TITLE), "TITLE is the decision's words");
        check("A known problem in this version can lose data.".equals(BuildWarningNotice.TEXT),
                "TEXT is the decision's example, verbatim");
        check("Continue".equals(BuildWarningNotice.BUTTON), "BUTTON is Continue");
        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases pass");
    }
}
