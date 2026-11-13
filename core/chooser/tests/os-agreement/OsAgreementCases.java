package com.nowhere.chooser;

import java.util.Locale;

/**
 * Cases for OsAgreement (NWP-20261114-11, docs/product-decisions.md 2026-10-24): the one gate is off, only an exact
 * "draft" ring reply shows the screen, setup goes on only with both confirmations, and the DRAFT text is not styled as a
 * licence and claims nothing beyond docs/privacy-claims.md §3. Since NWP-20261202-23 (docs/product-decisions.md
 * 2026-11-10, item 2) they also check the create form's acknowledgement: createStep waits on an unread gate, asks while
 * a draft reply's box is unticked and goes on every other reply; createAckShown only in create mode; createAckText
 * carries ACK and the DRAFT mark; the two refusal lines claim nothing about privacy. Exits 1 on any failure.
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
            {"CREATE_ACK_NEED", OsAgreement.CREATE_ACK_NEED}, {"CREATE_WAIT_TEXT", OsAgreement.CREATE_WAIT_TEXT},
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

        // The create form (NWP-20261202-23): the same ACK, behind the same one gate. A null reply is "not read yet":
        // with the gate off, Create waits and re-reads, ticked or not.
        check("CREATE_WAIT, CREATE_ASK and CREATE_GO are distinct", OsAgreement.CREATE_WAIT != OsAgreement.CREATE_ASK
                && OsAgreement.CREATE_ASK != OsAgreement.CREATE_GO && OsAgreement.CREATE_WAIT != OsAgreement.CREATE_GO);
        check("createStep(null, false) is CREATE_WAIT", OsAgreement.createStep(null, false) == OsAgreement.CREATE_WAIT);
        check("createStep(null, true) is CREATE_WAIT", OsAgreement.createStep(null, true) == OsAgreement.CREATE_WAIT);
        String[] draftReplies = {"draft", "draft ", " draft\n"};
        String[] otherReplies = {"", " ", "off", "ERR", "ERR unknown command", "DRAFT", "Draft", "drafty"};
        for (String r : draftReplies) {
            check("createStep draft unticked: createStep(" + show(r) + ", false) is CREATE_ASK",
                    OsAgreement.createStep(r, false) == OsAgreement.CREATE_ASK);
            check("createStep draft ticked: createStep(" + show(r) + ", true) is CREATE_GO",
                    OsAgreement.createStep(r, true) == OsAgreement.CREATE_GO);
            check("createAckShown(" + show(r) + ", true) is true", OsAgreement.createAckShown(r, true));
        }
        for (String r : otherReplies) {
            check("createStep(" + show(r) + ", false) is CREATE_GO", OsAgreement.createStep(r, false) == OsAgreement.CREATE_GO);
            check("createStep(" + show(r) + ", true) is CREATE_GO", OsAgreement.createStep(r, true) == OsAgreement.CREATE_GO);
            check("createAckShown(" + show(r) + ", true) is false", !OsAgreement.createAckShown(r, true));
        }
        check("createAckShown(null, true) is false", !OsAgreement.createAckShown(null, true));
        check("createAckShown off create mode: createAckShown(null, false) is false", !OsAgreement.createAckShown(null, false));
        for (String[] set : new String[][] {draftReplies, otherReplies}) {
            for (String r : set) {
                check("createAckShown off create mode: createAckShown(" + show(r) + ", false) is false",
                        !OsAgreement.createAckShown(r, false));
            }
        }
        String cat = OsAgreement.createAckText();
        check("createAckText holds ACK: " + show(cat), cat != null && cat.contains(OsAgreement.ACK));
        check("createAckText holds DRAFT_MARK while showsDraftMark(): " + show(cat),
                !OsAgreement.showsDraftMark() || (cat != null && cat.contains(OsAgreement.DRAFT_MARK)));
        check("createAckText is ACK, a newline and DRAFT_MARK: " + show(cat),
                (OsAgreement.ACK + "\n" + OsAgreement.DRAFT_MARK).equals(cat));
        check("CREATE_ACK_NEED names the box: " + show(OsAgreement.CREATE_ACK_NEED),
                lower(OsAgreement.CREATE_ACK_NEED).contains("box"));
        check("CREATE_WAIT_TEXT names the Create profile button: " + show(OsAgreement.CREATE_WAIT_TEXT),
                OsAgreement.CREATE_WAIT_TEXT != null && OsAgreement.CREATE_WAIT_TEXT.contains("Create profile"));
        for (String[] t : new String[][] {{"CREATE_ACK_NEED", OsAgreement.CREATE_ACK_NEED},
                {"CREATE_WAIT_TEXT", OsAgreement.CREATE_WAIT_TEXT}}) {
            for (String claim : new String[] {"nothing of yours", "do not know who you are", "anonymous", "guarantee",
                    "cannot be hacked", "private", "encrypt", "wipe"}) {
                check(t[0] + " makes no privacy claim (\"" + claim + "\")", !lower(t[1]).contains(claim));
            }
        }

        if (failures > 0) {
            System.err.println("  " + failures + " case(s) failed");
            System.exit(1);
        }
        System.out.println("  cases ok");
    }
}
