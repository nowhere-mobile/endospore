package com.nowhere.chooser;

/** NWP-20261118-17: the Storage screen's "Report this" rule. offer says the gateway answered with no grant
 *  (entitled == 0) while the wallet believes its purchased term has not run out yet. Parsed from the same
 *  GET-BILLING reply formatBilling renders, rather than threaded out of formatBilling, so the button and the
 *  text cannot come to disagree about which state the screen is in. A plan that this phone's own record says is
 *  moving (moving= > 0) is not reportable, because formatBilling says it is moving and the phone retries the move
 *  itself at every sign-in (docs/product-decisions.md, 2026-10-20, Q147). epochsec defaults to the weekly 604800
 *  when absent, as formatBilling's does. Pure and java.* only so a javac suite runs it (core/chooser/tests/plan-report). */
final class PlanReport {
    private PlanReport() {}

    static boolean offer(String billReply, long entitled, long nowSec) {
        if (billReply == null || !billReply.startsWith("OK")) return false;
        long through = -1, epochsec = 604800, moving = 0;
        for (String tok : billReply.split("\\s+")) {
            int eq = tok.indexOf('=');
            if (eq < 0) continue;
            try {
                long v = Long.parseLong(tok.substring(eq + 1));
                switch (tok.substring(0, eq)) {
                    case "through":  through = v;  break;
                    case "epochsec": epochsec = v; break;
                    case "moving":   moving = v;   break;
                    default: break;
                }
            } catch (NumberFormatException ignore) {}
        }
        if (through <= 0 || epochsec <= 0) return false;
        if (moving > 0) return false;
        return entitled == 0 && through >= nowSec / epochsec;
    }
}
