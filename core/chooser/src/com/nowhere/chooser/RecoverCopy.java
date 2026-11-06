package com.nowhere.chooser;

/**
 * What the Reset passphrase screen says about a non-OK RECOVER reply (NWP-20261115-10). Lifted out of
 * {@code ChooserActivity.buildRecoverScreen} -- pure, java.lang only -- so {@code test-recover-reply-java.sh} can compile
 * it with its cases and pin every code the daemon's recoverReply can send.
 *
 * <p>Every text here is blind-safe:
 * <ul>
 * <li>NWP-20261013-23: ERR-STORE is only ever sent AFTER the recovery code unwrapped, so naming the store leaks
 *     nothing about which profiles exist. No "nothing changed": a failure after the lease is compensated, but this
 *     reply does not prove every path was.</li>
 * <li>NWP-20261116-06: ERR-MOVED is also only ever sent AFTER the recovery code unwrapped, to someone who already
 *     holds the profile's recovery code. It says a seal from another phone landed while the reset ran, and that the
 *     reset refused rather than overwrite it. It leaks nothing about which profiles exist (h47 decisions, Q3).</li>
 * <li>NWP-20261007-09: no answer is not a failed reset -- the reset may have finished after this read gave up, and
 *     then the new passphrase is the one that works. Still blind: neither message says which field was wrong.</li>
 * <li>NWP-20261115-10: WEAK is decided from the typed name and new passphrase alone, before the words are parsed or
 *     the store is read, so it is the same for every profile and every recovery code. "Nothing was reset" is true:
 *     the daemon refused before the reset began.</li>
 * <li>Everything else, BLANK included, is the blind text: it does not say which field was wrong.</li>
 * </ul>
 *
 * <p>⚠ EQUALITY for ERR-STORE and ERR-MOVED, and "WEAK " with its space: a prefix match lets "ERR-STOR", "ERR-MOVE"
 * or "WEAKER" borrow a text.
 */
final class RecoverCopy {
    private RecoverCopy() {}

    /** The text for a non-OK RECOVER reply; null reads as "" (no answer). */
    static String failText(String r) {
        if (r == null) r = "";
        if ("ERR-STORE".equals(r)) return "Your recovery code was accepted, but the phone couldn't reach your storage. Try again.";
        if ("ERR-MOVED".equals(r)) return "Your recovery code was accepted, but this profile was just saved from another phone. Try again.";
        if (r.isEmpty()) return "the phone didn't answer, so the reset may or may not have gone through — try "
                + "signing in with your new passphrase first";
        if ("WEAK".equals(r) || r.startsWith("WEAK ")) {
            String reason = r.substring(4).trim();
            return reason.isEmpty() ? "Choose a stronger passphrase. Nothing was reset."
                    : "Choose a stronger passphrase — " + reason + ". Nothing was reset.";
        }
        return "couldn't reset — check the name and recovery code"; // blind: don't say which
    }
}
