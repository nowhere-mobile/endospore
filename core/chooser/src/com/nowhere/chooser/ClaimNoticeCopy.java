package com.nowhere.chooser;

import java.util.Arrays;

/**
 * NWP-20261208-04: Profile's notice for a code that could not be used (docs/backlog.md, "P0: `CREATE-CODE` joins an
 * identified purchase to `profileRefV2` seconds later from the same IP", slice 3, the chooser half). The decision
 * (docs/product-decisions.md, 2026-11-03, h55 #1): Profile says that the code could not be used, that the profile is
 * on the free plan, and that a code can be entered under Add credits. The content is decided; the words are drafts
 * for Chester's mockup.
 *
 * The wire: "GET-CLAIM-NOTICE\n" answers "NOTICE <n>\n" (n >= 1 codes the profile was not told about yet) or
 * "NONE\n"; "CLAIM-NOTICE-SHOWN\n<n>\n" clears the first n. An agent without the verbs answers something that is not
 * NOTICE, so count() is 0 and nothing shows. The decision's "Add credits" is the screen showAddCredits opens, which is
 * now headed and reached by "Start or extend a plan", so the drafts use the label on screen.
 *
 * Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-claim-notice-java.sh).
 */
final class ClaimNoticeCopy {
    private ClaimNoticeCopy() {}

    static final String GET_REQUEST = "GET-CLAIM-NOTICE\n";

    // DRAFT (NWP-20261208-04): mockup for Chester
    static final String TITLE_ONE = "Your code couldn't be used";
    static final String TITLE_MANY = "Your codes couldn't be used";
    static final String CONTEXT = "This profile is on the free plan.";
    static final String LINE = "You can enter a code under Start or extend a plan, in Storage.";
    static final String ADD = "Start or extend a plan";

    /** n for exactly "NOTICE <n>" (trimmed) with n a positive int; 0 for anything else. Never throws. */
    static int count(String reply) {
        if (reply == null) return 0;
        String r = reply.trim();
        if (!r.startsWith("NOTICE ")) return 0;
        String d = r.substring(7);
        if (!d.matches("[0-9]+")) return 0;
        try {
            return Integer.parseInt(d); // digits only, so never negative; NOTICE 0 is 0, no notice
        } catch (NumberFormatException e) {
            return 0; // more than an int holds
        }
    }

    /** The ack for the n codes the sheet told the profile about. */
    static String ackRequest(int n) {
        return "CLAIM-NOTICE-SHOWN\n" + n + "\n";
    }

    /** Routine: slot 0 opens Start or extend a plan, slot 1 (Got it) only closes the sheet. Both ack in the caller. */
    static PopupSheet.Confirm sheet(int n) {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, n == 1 ? TITLE_ONE : TITLE_MANY, CONTEXT,
                Arrays.asList(new PopupSheet.Line(LINE, null)),
                Arrays.asList(
                        new PopupSheet.Button(ADD, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.GOT_IT, PopupSheet.Style.OUTLINED)));
    }
}
