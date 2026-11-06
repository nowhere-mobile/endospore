package com.nowhere.chooser;

import java.text.DateFormat;
import java.util.Date;

/**
 * NWP-20261120-10 (#90; docs/product-decisions.md, 2026-10-30, harvest 48 #9): Storage shows the account's plans in the
 * order they run. The decision: the gateway sends the plans in run order with size and end date, and Storage shows
 * them, "for example '50 GB to Jan 21, then 10 GB to Jul 20'". Device-seen on lynx 2026-10-24: after a 50 GB code
 * redeemed with keep over a live 10 GB plan, Storage read "50 GB plan · 359 days left" and said nothing of the 10 GB
 * term after it.
 *
 * The input is GET-BILLING: the agent ships the list as plans=&lt;gb&gt;:&lt;through&gt;,... (core/agent billingLine). The agent
 * already drops the steps that have ended, sends the token only when two or more remain, and never while a purchase is
 * waiting, so this class only reads it. The words are the decision's example; the maintainer may change them at the device
 * run.
 *
 * Pure: java.lang, java.util and java.text only. Pinned by core/vendor-common/bin/test-plan-run-order-java.sh.
 */
final class PlanRunOrder {
    private PlanRunOrder() {}

    /** "&lt;gb&gt; GB to &lt;date&gt;, then &lt;gb&gt; GB to &lt;date&gt;" from a GET-BILLING reply, or null for fewer than two valid steps or any
     *  malformed step. Each date is the day after the step's last epoch, as formatBilling dates "Expires". */
    static String line(String billingReply, DateFormat df) {
        if (billingReply == null || !billingReply.startsWith("OK")) return null;
        // formatBilling's default, for its reason: an absent epochsec= means a weekly daemon.
        long epochsec = 604800;
        String plans = null;
        for (String tok : billingReply.split("\\s+")) {
            if (tok.startsWith("plans=")) {
                plans = tok.substring("plans=".length());
            } else if (tok.startsWith("epochsec=")) {
                try {
                    epochsec = Long.parseLong(tok.substring("epochsec=".length()));
                } catch (NumberFormatException ignore) {}
            }
        }
        if (plans == null || plans.isEmpty() || epochsec <= 0) return null;
        final String[] steps = plans.split(",", -1);
        if (steps.length < 2) return null;
        final StringBuilder sb = new StringBuilder();
        for (int i = 0; i < steps.length; i++) {
            final String step = steps[i];
            final int colon = step.indexOf(':');
            if (colon <= 0 || step.indexOf(':', colon + 1) >= 0) return null;
            final long gb, through;
            try {
                gb = Long.parseLong(step.substring(0, colon));
                through = Long.parseLong(step.substring(colon + 1));
            } catch (NumberFormatException e) {
                return null;
            }
            if (gb <= 0 || through <= 0) return null;
            if (i > 0) sb.append(", then ");
            sb.append(gb).append(" GB to ").append(df.format(new Date((through + 1) * epochsec * 1000L)));
        }
        return sb.toString();
    }
}
