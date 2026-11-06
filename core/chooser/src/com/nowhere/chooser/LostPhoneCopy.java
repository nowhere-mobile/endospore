package com.nowhere.chooser;

/**
 * The line the Change passphrase screen shows under its title: a lost phone is answered here (NWP-20261111-14,
 * NWP-20261114-22). Decided in docs/product-decisions.md, Q011: on 2026-10-20 ([BA]) a lost phone is revoked by
 * changing the passphrase, with one line of UI text saying so; on 2026-10-21 (dn-1104 #4) that line goes on this
 * screen, under its title, because that is where the lever is when someone looks for it; on 2026-10-22 (#45,
 * dn-1107 #2) its words: {@link #TIED} on a profile tied to the phone's chip, {@link #NOT_TIED} on one not tied. One
 * line for every profile was not chosen. Pure, java.lang only, so {@code test-lost-phone-line-java.sh} can compile it
 * with its cases, which check both texts byte for byte against the decision; the same suite pins where
 * {@code ProfileActivity.showChangePass} adds it and that it is set from the daemon's SE-STATUS reply.
 *
 * <p>Why each claim is true: the change (rotateVault in core/agent) moves every store ref and retires every other
 * phone's chip slot, and re-wraps the pass slot to the new passphrase. So the old passphrase opens nothing anywhere
 * (NOT_TIED), and a tied lost phone's slot is gone whatever passphrase it is given (TIED). An offline sign-in on the
 * lost phone lands an empty local session, not this profile, so it is no counterexample. On a tied profile a phone
 * you keep loses its chip slot too, so it is added again with the 12 words (TIED's second sentence). The phone you
 * are holding is the {@code warn} line's job, directly below.
 *
 * <p>Which text {@link #line} picks: {@code OK TIED} and {@code OK TIED PARTIAL} (SE-STATUS, se_tie.go) are TIED. A
 * partly tied vault has chip slots and no pass slot left, so the old passphrase alone opens nothing there either and a
 * kept phone still needs the 12 words. Every other reply is NOT_TIED: {@code OK UNTIED}, {@code OK NOCHIP},
 * {@code OK OTHER}, any {@code ERR-*}, and the "" of a timeout or an unreachable daemon, null included. NOT_TIED is the
 * fallback because it is true of every vault shape (a tied profile's old passphrase also stops opening it), while
 * TIED's 12-word clause is false on an untied profile, where a kept phone needs only the new passphrase. The match is
 * exact after a trim, never a prefix, so a new reply never reads as tied by accident.
 *
 * <p>What it deliberately does NOT claim: a lost phone that still holds a cold-locked session keeps that session
 * until the 12 h cold-lock wipe or power-off, because a resume is checked on the phone itself, never against the
 * store. That is why the line says "open this profile", never "erases", "wipes" or "locks it out of everything". And
 * it never names recovery as the lever: the 12 words answer a forgotten passphrase, never a compromised one
 * (2026-09-15). TIED names the 12 words only as the way to add a kept phone again, after the passphrase change.
 */
final class LostPhoneCopy {
    private LostPhoneCopy() {}

    static final String TIED = "Lost a phone? Change your passphrase: the lost phone can no longer open this profile. "
            + "You'll add each phone you keep again with your 12 words.";
    static final String NOT_TIED = "Lost a phone? Change your passphrase: the old one stops opening this profile "
            + "anywhere.";

    /** The line for a SE-STATUS reply: TIED on {@code OK TIED} or {@code OK TIED PARTIAL}, else NOT_TIED. */
    static String line(String seStatus) {
        String s = seStatus == null ? "" : seStatus.trim();
        return "OK TIED".equals(s) || "OK TIED PARTIAL".equals(s) ? TIED : NOT_TIED;
    }
}
