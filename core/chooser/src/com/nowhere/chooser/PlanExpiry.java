package com.nowhere.chooser;

import java.text.DateFormat;
import java.util.Date;

/**
 * NWP-20261118-08 (#53; docs/product-decisions.md, 2026-10-30, harvest 48 #8): the plan-expiry notice, decided off-device.
 *
 * Before this, nothing on the phone named a plan's end. The end date and the ledger's deletion date showed only on
 * Profile › Storage (ProfileActivity.formatBilling), so a customer who never opened that screen got no word before the
 * plan ended, nor through the grace before the ledger's deadline deletes a profile over the free 1 GB. The decision
 * builds the warnings on the phone (30 and 7 days before the end, on the end date, and through grace) and drops the
 * storefront email for good: the storefront keeps no customer address.
 *
 * The inputs are the two reads the Storage screen makes: GET-BILLING (the local wallet: through=, epochsec=, deadline=,
 * plangb=, pending=, moving=) and GET-ENTITLEMENT (the gateway's entitled=). The parse is formatBilling's, copied rather
 * than shared (formatBilling is an instance method of the Storage screen, and another slice owns it).
 *
 * The rule reuses that screen's states, so no notice tells a customer something the screen would not:
 *   - entitled < 0 is "the gateway did not answer" (formatBilling's two-paint rule): never decide on it. -1 is not 0.
 *     A store-refused footprint (NOWHERE-1313) comes back as an error line, which reads as -1 here.
 *   - a live term warns only when entitled > 0 (the screen's live arm). entitled == 0 on a live term is its
 *     "stranger" arm, which is not an expiry.
 *   - pending= (a purchase not yet redeemed) and moving= (the plan is moving to a new passphrase) say nothing: the plan
 *     is about to change, so "expires" would be false.
 *   - grace needs entitled == 0 AND the ledger's deadline, still ahead. A positive entitled past the wallet's term is a
 *     plan this wallet does not hold: say nothing.
 * The grace wording keeps the 2026-08-09 correction (docs/billing-plan-model.md: the WHOLE profile stays free when it
 * fits the free 1 GB, or the whole profile goes) and Q082 (read-only applies only past the free 1 GB).
 *
 * Pure: java.lang, java.util and java.text only. Pinned by core/vendor-common/bin/test-plan-expiry-java.sh.
 */
final class PlanExpiry {
    private PlanExpiry() {}

    static final int NONE = 0, SOON = 1, WEEK = 2, TODAY = 3, GRACE = 4;

    /** The first check waits this long after a sign-in. GET-ENTITLEMENT is serialized in the daemon (not in
     *  concurrentSafeCmd) and holds the session lock for a gateway round trip plus a footprint walk; the minutes
     *  after a switch are when the serialized post-switch ops (restores, the Auto sweep's MATERIALIZE-APP) run. */
    static final long PLAN_FIRST_DELAY_MS = 10 * 60 * 1000L;
    /** The next check after one whose GET-ENTITLEMENT answered. */
    static final long PLAN_RECHECK_MS = 24 * 60 * 60 * 1000L;
    /** The next check after one whose GET-ENTITLEMENT did not answer (it can queue behind a restore and miss its bound). */
    static final long PLAN_RETRY_MS = 60 * 60 * 1000L;

    /** ProfileActivity.entitledFrom's rule: the entitled= value of an OK GET-ENTITLEMENT reply, else -1. */
    static long entitled(String reply) {
        if (reply == null || !reply.startsWith("OK")) return -1;
        for (String tok : reply.split("\\s+")) {
            if (!tok.startsWith("entitled=")) continue;
            try {
                return Long.parseLong(tok.substring("entitled=".length()));
            } catch (NumberFormatException ignore) {
                return -1;
            }
        }
        return -1;
    }

    /** The GET-BILLING fields this needs, parsed as formatBilling parses them. */
    private static final class Bill {
        boolean ok;
        long through = -1, epochsec = 604800, deadline = -1, plangb = -1, pending = 0, moving = 0;
    }

    private static Bill parse(String r) {
        final Bill p = new Bill();
        p.ok = r != null && r.startsWith("OK");
        if (!p.ok) return p;
        for (String tok : r.split("\\s+")) {
            int eq = tok.indexOf('=');
            if (eq < 0) continue;
            try {
                long v = Long.parseLong(tok.substring(eq + 1));
                switch (tok.substring(0, eq)) {
                    case "through":  p.through = v;  break;
                    case "epochsec": p.epochsec = v; break;
                    case "deadline": p.deadline = v; break;
                    case "plangb":   p.plangb = v;   break;
                    case "pending":  p.pending = v;  break;
                    case "moving":   p.moving = v;   break;
                    default: break;
                }
            } catch (NumberFormatException ignore) {
                // a bad number is ignored, as formatBilling does
            }
        }
        return p;
    }

    /** The stage to show for this wallet (GET-BILLING), the gateway's entitled bytes and the time now (unix seconds). */
    static int stage(String billing, long entitled, long nowSec) {
        final Bill p = parse(billing);
        if (!p.ok || p.through <= 0 || p.epochsec <= 0) return NONE;
        if (p.pending > 0) return NONE;
        if (p.moving > 0) return NONE;
        if (entitled < 0) return NONE;
        final long nowEp = nowSec / p.epochsec;
        final long left = p.through - nowEp;
        if (left >= 0) {
            if (entitled <= 0) return NONE;
            if (left > 30) return NONE;
            if (left >= 8) return SOON;
            if (left >= 1) return WEEK;
            return TODAY;
        }
        return entitled == 0 && p.deadline > 0 && p.deadline >= nowEp ? GRACE : NONE;
    }

    /** The notice title. Call it only when stage() is not NONE; "" for a reply stage() would refuse. */
    static String title(String billing, long nowSec, DateFormat df) {
        final Bill p = parse(billing);
        if (!p.ok || p.through <= 0 || p.epochsec <= 0) return "";
        final long n = p.through - nowSec / p.epochsec;
        if (n > 0) return "Your plan ends in " + n + (n == 1 ? " day" : " days");
        if (n == 0) return "Your plan ends today";
        return "Your plan has expired";
    }

    /** The notice text. Call it only when stage() is not NONE; "" for a reply stage() would refuse. */
    static String text(String billing, long nowSec, DateFormat df) {
        final Bill p = parse(billing);
        if (!p.ok || p.through <= 0 || p.epochsec <= 0) return "";
        final long left = p.through - nowSec / p.epochsec;
        final String g = p.plangb > 0 ? p.plangb + " GB plan" : "plan";
        final String keep = " Start or extend a plan in Profile › Storage to keep your data.";
        if (left > 0) return "Your " + g + " expires " + date(p.through, p.epochsec, df) + "." + keep;
        if (left == 0) return "Your " + g + " expires today." + keep;
        return "Your plan expired " + date(p.through, p.epochsec, df) + ". Your data is kept until "
                + date(p.deadline, p.epochsec, df) + ". After that it is deleted, unless it fits the free 1 GB — then it "
                + "stays as a free profile. Over 1 GB, nothing new can be added until you start a plan.";
    }

    /** The first second after epoch <ep>, as Storage dates it: (ep + 1) * epochsec. */
    private static String date(long ep, long epochsec, DateFormat df) {
        return df.format(new Date((ep + 1) * epochsec * 1000L));
    }
}
