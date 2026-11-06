package com.nowhere.chooser;

/**
 * The first-boot OS agreement screen: its one gate and its text (NWP-20261114-11). Decided in
 * docs/product-decisions.md, 2026-10-24: the screen is built now, with DRAFT text, on beta-ring images only, behind one
 * gate whose flip waits for counsel's review of the screen and the text together. Backlog row: "The first-boot OS
 * agreement screen (Nowhere Mobile LLC), with DRAFT text and the affirmative lost-passphrase acknowledgement, shown on
 * beta-ring images only behind one gate".
 *
 * <p>The ring signal (NWP-20261114-13): beta-setup bakes {@code NOWHERE_OS_AGREEMENT=draft}, and the daemon's
 * {@code GET-OS-AGREEMENT} answers {@code draft} or {@code off}. A prod/stable image bakes no ring, so it answers
 * {@code off}. {@link #shouldShow} takes only an exact {@code draft} (after a trim) while the gate is off, so null,
 * "", {@code off}, an {@code ERR} reply or a daemon without the verb all hide the screen. Every failure hides the DRAFT
 * text; no failure shows it.
 *
 * <p>What the text is (docs/legal-fact-pack.md §2.3, §2.5, §8; docs/legal-checklist.md item 7): disclaimers, service
 * terms and what the phone does and does not keep, from Nowhere Mobile LLC. It is NOT styled or titled as a licence over
 * the code: the OS source is already Apache-2.0, and a second licence on top invites a conflict. The lost-passphrase
 * acknowledgement ({@link #ACK}) is its own confirmation, never one sentence with {@link #AGREE}. Every claim stays
 * inside docs/privacy-claims.md §3, with its qualifier in the same paragraph (§4 rule 2).
 *
 * <p>Pure, java.lang only, so {@code test-os-agreement-java.sh} compiles it as-is with its cases. The model for one
 * gate in one file is nowhere-cloud's COPY GATE ({@code cmd/storefront/copygates.go}).
 */
final class OsAgreement {
    private OsAgreement() {}

    // ---- THE GATE ------------------------------------------------------------------------------------------------
    // PRODUCTION_APPROVED is the one switch. It is false: only a beta-ring image (GET-OS-AGREEMENT = draft) shows the
    // screen, and it shows the DRAFT mark. To flip it, open its own PR that changes this one line. That PR cites where
    // counsel's approval of the screen AND the text together is recorded (backlog §D, "Draft the OS and storefront
    // agreements for counsel review"). The same PR removes the DRAFT mark and puts the approved text in place of the
    // draft text below. There is no other flip: not the ring key, not an env var, not a runtime flag, not a build tag.
    static final boolean PRODUCTION_APPROVED = false;

    /** The version of the text. The device records it on accept, and asks again when it changes. */
    static final String VERSION = "draft-1";

    /** True when the first-run flow shows the screen, for the daemon's GET-OS-AGREEMENT reply. */
    static boolean shouldShow(String daemonReply) {
        return PRODUCTION_APPROVED || (daemonReply != null && "draft".equals(daemonReply.trim()));
    }

    /** True while the text is not approved: the screen shows {@link #DRAFT_MARK} at its top. */
    static boolean showsDraftMark() {
        return !PRODUCTION_APPROVED;
    }

    /** Setup goes on only with both confirmations: the agreement AND the lost-passphrase acknowledgement. */
    static boolean canContinue(boolean accepted, boolean acknowledged) {
        return accepted && acknowledged;
    }

    // ---- THE TEXT (DRAFT) ----------------------------------------------------------------------------------------
    static final String TITLE = "Before you set up this phone";

    static final String DRAFT_MARK = "DRAFT -- not yet reviewed by counsel. This text will change.";

    static final String BODY_FROM =
            "These terms are from Nowhere Mobile LLC, which makes the Nowhere operating system on this phone.";
    // BODY_KEEPS and BODY_WE_SEE carry their qualifiers (docs/privacy-claims.md §3 and §4 rule 2); the cases pin them.
    static final String BODY_KEEPS = "What this phone keeps. Your profiles are not kept on this phone. At sign-in, "
            + "your profile comes back from your store. At sign-out or power-off, the phone wipes it. Some phone "
            + "settings stay on the phone, for example which SIM is tied to which profile.";
    static final String BODY_WE_SEE = "What we keep. There are no accounts. We see only encrypted pieces of your data, "
            + "their sizes, and when and from which network address they are stored. We cannot read them.";
    static final String BODY_PASSPHRASE = "Your passphrase. Your passphrase makes the key to your data. We keep no copy "
            + "of it and we cannot reset it. You also get a 12-word recovery code when you make a profile.";
    static final String BODY_SOFTWARE = "The software. The source code of this operating system is public under the "
            + "Apache-2.0 terms. These terms do not change the rights that those terms give you.";
    static final String BODY_WARRANTY = "No warranty. The phone and the service are given as they are, without "
            + "warranty, to the extent the law allows. This does not remove rights that the law of your country gives "
            + "you and that cannot be waived.";

    static final String BODY = BODY_FROM + "\n\n" + BODY_KEEPS + "\n\n" + BODY_WE_SEE + "\n\n" + BODY_PASSPHRASE
            + "\n\n" + BODY_SOFTWARE + "\n\n" + BODY_WARRANTY;

    /** The first confirmation: the terms above. */
    static final String AGREE = "I have read these terms and I agree to them.";

    /** The second confirmation, on its own control: a lost passphrase cannot be recovered by anyone. */
    static final String ACK = "I understand that if I lose my passphrase and my 12-word recovery code, no one can "
            + "recover my data. Not Nowhere, and not anyone else.";

    static final String ACCEPT = "Agree and continue";
}
