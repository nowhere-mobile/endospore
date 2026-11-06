package com.nowhere.chooser;

/** NWP-20261031-11: the Add credit screen's convert-or-keep question (docs/product-decisions.md, 2026-10-20: a bigger
 *  plan starts at once). The words are h51 #5's (2026-11-01, NWP-20261125-12). The phone cannot know the size of the
 *  code it is about to redeem, so the question is put whenever a paid plan is live, in words that fit either size.
 *  Convert means the bigger plan's size in both directions (h49 #10): a bigger code takes the current plan's time, and
 *  a smaller code's time goes onto the current plan, each at its value. Keep runs the bigger plan first and the smaller
 *  one after it. Each option has a grey line under it. Pure and java.lang only so a javac suite runs it. */
final class PlanChoice {
    private PlanChoice() {}

    static final String CONVERT = "Put all my time on the bigger plan (recommended)";
    static final String CONVERT_NOTE =
            "Whichever is bigger, this code or my current plan, the other's time is added to it at its value.";
    static final String KEEP = "Keep each plan at its own size";
    static final String KEEP_NOTE = "The bigger plan runs first and the smaller one starts when it ends.";

    /** True only for an "OK " GET-BILLING line naming a paid size (plangb > 0) whose term has not run out.
     *  `through` is the LAST paid epoch (core/agent/billing.go Wallet.PaidThrough), the same reading as
     *  PlanReport.offer and formatBilling's (through + 1) * epochsec expiry, so the term is live through
     *  the end of that epoch (NWP-20261108-22). A missing or malformed through, epochsec or plangb is no live term. */
    static boolean shouldAsk(String billingReply, long nowSec) {
        if (billingReply == null || !billingReply.startsWith("OK ")) return false;
        long through = -1, epochsec = -1, plangb = -1;
        for (String tok : billingReply.split("\\s+")) {
            int eq = tok.indexOf('=');
            if (eq < 0) continue;
            try {
                long v = Long.parseLong(tok.substring(eq + 1));
                switch (tok.substring(0, eq)) {
                    case "through": through = v; break;
                    case "epochsec": epochsec = v; break;
                    case "plangb": plangb = v; break;
                    default: break;
                }
            } catch (NumberFormatException ignore) {}
        }
        if (plangb <= 0 || through <= 0 || epochsec <= 0) return false;
        return nowSec < (through + 1) * epochsec;
    }

    /** The daemon request for a redeem: plain CLAIM when the question was not put, CLAIM2 with the answer when it was. */
    static String claimRequest(String code, boolean ask, boolean keep) {
        if (!ask) return "CLAIM\n" + code + "\n";
        return "CLAIM2\n" + code + "\n" + (keep ? "keep" : "convert") + "\n";
    }
}
