package com.nowhere.chooser;

/**
 * NWP-20261109-05: what the gate paints when an NFC tap fails, lifted out of ChooserActivity.gateNfcResult with
 * java.lang only so a javac suite can execute it (core/chooser/tests/nfc-shuttle).
 *
 * The daemon answers a bare ERR whatever went wrong, so a dropped tap reaches the gate as {@link
 * NfcShuttle#LINK_LOST} (minted by the shuttle, which saw its own transceive throw) or as a detail the chooser
 * itself produced ("closed", "nfc-io", "not-fido").
 */
final class NfcTapVerdict {
    private NfcTapVerdict() {}

    static final String DROP_LINE = "Didn't catch the key — hold it flat and steady on the back, then tap again.";

    static final String FRESH_FAIL = "Couldn't sign in with that key — check your name and passphrase and try again.";

    /**
     * The first two lines of ChooserActivity.resume()'s NEEDKEY text, WITHOUT its third line ("…tap Retry."): a
     * tap-first resume fails before Resume is pressed, when the Retry/Cancel row is not on screen
     * (NWP-20260824-05). A resume asserts from the cold-lock marker alone and verifies the typed entry only after
     * the tap succeeds, so this text never names the PIN, the passphrase or Retry.
     */
    static final String RESUME_KEY_FAIL = "Couldn't read your security key.\nHold it flat against the back of the phone — no rush.";

    /** Exactly what gateNfcResult paints for a failed tap. */
    static String failText(boolean resumeMode, String detail) {
        if (resumeMode) {
            if (NfcShuttle.LINK_LOST.equals(detail)) return DROP_LINE;
            return looksDropped(detail) ? DROP_LINE : RESUME_KEY_FAIL;
        }
        // Tested FIRST: LINK_LOST contains "nfc" and "lost", and the fresh gate must not tell the typist that the
        // name and passphrase opened a key-enrolled profile (blind login).
        if (NfcShuttle.LINK_LOST.equals(detail)) return FRESH_FAIL;
        return looksDropped(detail) ? DROP_LINE : FRESH_FAIL;
    }

    /** The substring rule gateNfcResult used before this lift, byte for byte. */
    private static boolean looksDropped(String detail) {
        String d = detail == null ? "" : detail.toLowerCase();
        return d.contains("out of date") || d.contains("nfc") || d.contains("not-fido")
                || d.contains("tag") || d.contains("lost") || d.contains("transceive")
                || d.contains("closed") || d.contains("timeout");
    }
}
