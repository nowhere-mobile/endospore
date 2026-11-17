package com.nowhere.chooser;

/** NWP-20261203-17: the cases for SweepFailNotice, run by core/vendor-common/bin/test-sweep-fail-notice-java.sh. */
public final class SweepFailNoticeCases {
    static int bad = 0;

    static void eq(String id, String what, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        bad++;
    }

    static void act(int total, int done, int hardFailed, SweepFailNotice.Act want) {
        eq("C2", "action(" + total + ", " + done + ", " + hardFailed + ")", want,
                SweepFailNotice.action(total, done, hardFailed));
    }

    public static void main(String[] a) {
        int b0 = bad;
        eq("C1", "TOKENS.length", 10, SweepOutcome.TOKENS.length);
        int hard = 0;
        for (String t : SweepOutcome.TOKENS) {
            boolean want = "fetch-failed".equals(t) || "install-failed".equals(t) || "error".equals(t);
            boolean wantTok = SweepOutcome.FETCH_FAILED.equals(t) || SweepOutcome.INSTALL_FAILED.equals(t)
                    || SweepOutcome.ERROR.equals(t);
            eq("C1", "the literals and SweepOutcome agree on " + t, want, wantTok);
            eq("C1", "hard(" + t + ")", want, SweepFailNotice.hard(t));
            if (SweepFailNotice.hard(t)) hard++;
        }
        eq("C1", "hard tokens", 3, hard);
        eq("C1", "hard(null)", false, SweepFailNotice.hard(null));
        eq("C1", "hard(x)", false, SweepFailNotice.hard("x"));
        if (bad == b0) System.out.println("ok C1 hard() is true for fetch-failed, install-failed and error only");

        b0 = bad;
        act(3, 0, 3, SweepFailNotice.Act.POST);   // every app failed (the ticket's sweeps)
        act(1, 0, 1, SweepFailNotice.Act.POST);   // the one app failed
        act(3, 0, 2, SweepFailNotice.Act.POST);   // some failed, none landed
        act(5, 3, 2, SweepFailNotice.Act.POST);   // partly failed: Chester's "2 of 5"
        act(3, 0, 0, SweepFailNotice.Act.KEEP);   // a pass cut before any app ran or failed hard
        act(0, 0, 0, SweepFailNotice.Act.KEEP);   // nothing to do
        act(3, 3, 0, SweepFailNotice.Act.CANCEL); // a clean pass clears the notice
        act(3, 1, 0, SweepFailNotice.Act.CANCEL); // a pass that landed one app and failed none
        if (bad == b0) System.out.println("ok C2 action posts on any hard failure, cancels on a clean landing, else keeps");

        b0 = bad;
        eq("C3", "title(0, 3)", null, SweepFailNotice.title(0, 3));
        eq("C3", "title(1, 1)", "1 app could not be fetched", SweepFailNotice.title(1, 1));
        eq("C3", "title(2, 5)", "2 of 5 apps could not be fetched", SweepFailNotice.title(2, 5));
        eq("C3", "title(3, 3)", "3 of 3 apps could not be fetched", SweepFailNotice.title(3, 3));
        eq("C3", "TEXT", "Open Your apps and tap Install pending apps now, or tap an app to try it again.",
                SweepFailNotice.TEXT);
        if (bad == b0) System.out.println("ok C3 the draft title and text");

        b0 = bad;
        eq("C4", "NOTICE_ID", 0x0A2F, SweepFailNotice.NOTICE_ID);
        if (bad == b0) System.out.println("ok C4 NOTICE_ID is 0x0A2F");

        b0 = bad;
        eq("C5", "offersRetry(POST)", true, SweepFailNotice.offersRetry(SweepFailNotice.Act.POST));
        eq("C5", "offersRetry(CANCEL)", false, SweepFailNotice.offersRetry(SweepFailNotice.Act.CANCEL));
        eq("C5", "offersRetry(KEEP)", false, SweepFailNotice.offersRetry(SweepFailNotice.Act.KEEP));
        // UnarchiveService.FG_ID 0x0A2D, FG_ID + 1 (NWP-20261203-18's Pause) and NOTICE_ID (its Stop, FG_ID + 2).
        for (int used : new int[] {SweepFailNotice.NOTICE_ID, 0x0A2D, 0x0A2E}) {
            eq("C5", "RETRY_REQUEST differs from 0x" + Integer.toHexString(used), true,
                    SweepFailNotice.RETRY_REQUEST != used);
        }
        eq("C5", "ACTION_RETRY is this app's action", true,
                SweepFailNotice.ACTION_RETRY.startsWith("com.nowhere.chooser.action."));
        if (bad == b0) System.out.println("ok C5 the action rides POST only, with its own request code and intent action");

        b0 = bad;
        eq("C6", "RETRY", "Try again", SweepFailNotice.RETRY);
        if (bad == b0) System.out.println("ok C6 the draft action label");

        System.exit(bad == 0 ? 0 : 1);
    }
}
