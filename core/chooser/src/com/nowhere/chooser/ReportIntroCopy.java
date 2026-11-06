package com.nowhere.chooser;

/**
 * The intros of the phone's two issue reporters (NWP-20261118-18): {@link #PROFILE} for Profile › Report an issue
 * ({@code ProfileActivity.showReportIssue}) and {@link #GATE} for the owner's Report a device issue
 * ({@code ChooserActivity.buildReportScreen}). Lifted out of those screens -- pure, java.lang only -- so
 * {@code test-report-intro-copy-java.sh} can compile the real copy with its cases; the chooser itself does not compile
 * off the build host. Backlog row: "The phone's two issue reporters lack `/support`'s warning never to send a profile
 * name or passphrase, though their note is free text".
 *
 * <p>WHERE {@link #NEVER_SEND} COMES FROM. It is byte for byte the sentence nowhere-cloud's {@code /support} page
 * (cmd/storefront/templates/support.html) shows live and ungated (NWC-20261016-14). The sentence after it there is
 * held by that page's SupportNeverAsk COPY GATE until counsel clears it, so it stays off the phone too: a claim we
 * cannot defend is not made (docs/privacy-claims.md).
 *
 * <p>WHY "YOUR PASSPHRASE" LEFT THE REMOVED LIST. Both screens take a free-text note. The agent's handleReportIssue
 * hands redactIssueSecrets only the spellings of the live profile name plus generic patterns (key=value secrets,
 * tokens, emails, MACs, phone numbers); at the gate there is no live profile, so not even the name. A passphrase typed
 * into the note is therefore SENT. The old Profile intro said the passphrase was removed, which invites a user with a
 * sign-in problem to type it in. The removed list now names the diagnostics only, and both intros end by saying never
 * to send it.
 */
final class ReportIntroCopy {
    private ReportIntroCopy() {}

    /** /support's live sentence, byte for byte. Both intros end with it. */
    static final String NEVER_SEND = "Never send us your profile name or passphrase.";

    /** Profile › Report an issue. */
    static final String PROFILE = "This sends your device model, OS version, and a recent tail of app diagnostics so "
            + "support can look into a problem. It's anonymous — there's no account. Before anything is sent, "
            + "passwords, phone numbers, contacts, and anything that could identify you are removed from the "
            + "diagnostics. You can review exactly what's sent first. " + NEVER_SEND;

    /** The owner's Report a device issue, at the gate. */
    static final String GATE = "Sends scrubbed device diagnostics (update, setup and system logs) anonymously to "
            + "support. Profile data and sign-in history are never included. Don't put personal details in the "
            + "note. " + NEVER_SEND;
}
