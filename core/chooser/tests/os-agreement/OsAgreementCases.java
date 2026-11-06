package com.nowhere.chooser;

import java.util.Locale;

/**
 * Cases for OsAgreement (NWP-20261114-11, docs/product-decisions.md 2026-10-24): the one gate is off, only an exact
 * "draft" ring reply shows the screen, setup goes on only with both confirmations, and the DRAFT text is not styled as a
 * licence and claims nothing beyond docs/privacy-claims.md §3. Exits 1 on any failure.
 */
public class OsAgreementCases {
    private static int failures = 0;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    private static String show(String s) {
        return s == null ? "null" : "\"" + s.replace("\r", "\\r").replace("\n", "\\n") + "\"";
    }

    private static String lower(String s) {
        return s == null ? "" : s.toLowerCase(Locale.ROOT);
    }

    // The two BODY paragraphs that carry their qualifiers (privacy-claims.md §4 rule 2). The literal here is the pin: a
    // change of these words needs a change of this case.
    private static final String PINNED_KEEPS = "What this phone keeps. Your profiles are not kept on this phone. At "
            + "sign-in, your profile comes back from your store. At sign-out or power-off, the phone wipes it. Some "
            + "phone settings stay on the phone, for example which SIM is tied to which profile.";
    private static final String PINNED_WE_SEE = "What we keep. There are no accounts. We see only encrypted pieces of "
            + "your data, their sizes, and when and from which network address they are stored. We cannot read them.";

    public static void main(String[] args) {
        // The gate is off until counsel approves the screen and the text together, and while it is off the DRAFT mark
        // shows.
        check("PRODUCTION_APPROVED is false", !OsAgreement.PRODUCTION_APPROVED);
        check("showsDraftMark() is true while the gate is off", OsAgreement.showsDraftMark());

        // Only an exact "draft" (after a trim) shows the screen; every other reply, null included, hides it.
        for (String r : new String[] {null, "", " ", "off", "off\n", "ERR", "ERR unknown command", "DRAFT", "Draft",
                "drafty", "draft-1", "on", "OK"}) {
            check("shouldShow(" + show(r) + ") is false", !OsAgreement.shouldShow(r));
        }
        for (String r : new String[] {"draft", "draft ", " draft\n", "draft\r\n"}) {
            check("shouldShow(" + show(r) + ") is true", OsAgreement.shouldShow(r));
        }

        // Setup goes on only with the agreement AND the acknowledgement.
        check("canContinue(false, false) is false", !OsAgreement.canContinue(false, false));
        check("canContinue(true, false) is false", !OsAgreement.canContinue(true, false));
        check("canContinue(false, true) is false", !OsAgreement.canContinue(false, true));
        check("canContinue(true, true) is true", OsAgreement.canContinue(true, true));

        String[][] texts = {
            {"TITLE", OsAgreement.TITLE}, {"DRAFT_MARK", OsAgreement.DRAFT_MARK}, {"BODY", OsAgreement.BODY},
            {"AGREE", OsAgreement.AGREE}, {"ACK", OsAgreement.ACK}, {"ACCEPT", OsAgreement.ACCEPT},
            {"VERSION", OsAgreement.VERSION},
        };
        for (String[] t : texts) check(t[0] + " is set", t[1] != null && !t[1].trim().isEmpty());

        // Not styled or titled as a licence over the Apache-2.0 code (legal-fact-pack.md §2.5).
        for (String[] t : texts) {
            String l = lower(t[1]);
            for (String banned : new String[] {"eula", "end user license", "license agreement"}) {
                check(t[0] + " does not contain \"" + banned + "\": " + show(t[1]), !l.contains(banned));
            }
        }

        check("DRAFT_MARK says DRAFT: " + show(OsAgreement.DRAFT_MARK),
                OsAgreement.DRAFT_MARK != null && OsAgreement.DRAFT_MARK.contains("DRAFT"));
        check("BODY names Nowhere Mobile LLC",
                OsAgreement.BODY != null && OsAgreement.BODY.contains("Nowhere Mobile LLC"));

        // The acknowledgement names the passphrase and says no one, Nowhere included, can recover it
        // (legal-fact-pack.md §2.3, legal-checklist.md item 7).
        String ack = lower(OsAgreement.ACK);
        check("ACK names the passphrase: " + show(OsAgreement.ACK), ack.contains("passphrase"));
        check("ACK says no one can recover: " + show(OsAgreement.ACK), ack.contains("no one") && ack.contains("recover"));
        check("ACK names Nowhere: " + show(OsAgreement.ACK), ack.contains("nowhere"));

        // Two separate confirmations: neither text holds the other.
        String agree = OsAgreement.AGREE == null ? "" : OsAgreement.AGREE;
        String ackRaw = OsAgreement.ACK == null ? "" : OsAgreement.ACK;
        check("ACK is not part of AGREE", !agree.contains(ackRaw));
        check("AGREE is not part of ACK", !ackRaw.contains(agree));
        check("AGREE does not name the passphrase: " + show(agree), !lower(agree).contains("passphrase"));

        // BODY keeps to privacy-claims.md §3: the rejected over-claims stay out, the qualified paragraphs stay in.
        String body = lower(OsAgreement.BODY);
        for (String over : new String[] {"nothing of yours", "do not know who you are", "anonymous", "guarantee",
                "cannot be hacked"}) {
            check("BODY does not say \"" + over + "\"", !body.contains(over));
        }
        String b = OsAgreement.BODY == null ? "" : OsAgreement.BODY;
        check("BODY holds the pinned \"What this phone keeps\" paragraph", b.contains(PINNED_KEEPS));
        check("BODY holds the pinned \"What we keep\" paragraph", b.contains(PINNED_WE_SEE));

        if (failures > 0) {
            System.err.println("  " + failures + " case(s) failed");
            System.exit(1);
        }
        System.out.println("  cases ok");
    }
}
