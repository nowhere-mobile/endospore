package com.nowhere.chooser;

/** NWP-20261114-29: the parse of the daemon's LIST-FIDO2 reply, lifted out of ProfileActivity.loadEnrolledKeys so
 *  javac can run it off the build host (java.* only). The reply is NONE, LOCAL, ERR, or "OK <n>" and then one line per
 *  key, "<credID> <added> <transport> <label...>". Only the FIRST line is the header: a credID is standard base64, so
 *  a random one begins "OK" for about 1 key in 4096, and a loop that skipped every "OK..." line hid that key.
 *  NWP-20261116-29: also the text ProfileActivity.confirmRemoveKey shows for a REMOVE-FIDO2-KEY reply (removeText).
 *  NWP-20261119-11: also the text for an ENROLL-FIDO2 reply (enrollText) and a failed NFC FINISH (nfcFinishText). */
final class Fido2KeyList {
    private Fido2KeyList() {}

    /** The records of an answered reply, each {credID, added, transport ("" when absent), label ("" when absent)};
     *  an empty list for NONE, LOCAL and "OK 0". Null when the reply is not an answer (null, "", ERR, anything else):
     *  the caller then says it could not read the keys, never that there are none (NWP-20261006-23). */
    static java.util.List<String[]> parse(String reply) {
        if (reply == null) return null;
        // The -1 limit keeps empty fields: a plain split("\n") drops them all for "\n", and lines[0] would throw.
        String[] lines = reply.split("\n", -1);
        String head = lines[0].trim();
        if (!(head.startsWith("OK") || head.equals("NONE") || head.equals("LOCAL"))) return null;
        java.util.List<String[]> keys = new java.util.ArrayList<>();
        for (int i = 1; i < lines.length; i++) {
            String line = lines[i].trim();
            if (line.isEmpty()) continue;
            // transport is a fixed 3rd field ("usb"/"nfc"/"-"), so the label stays "the rest of the line"; a legacy
            // line with no transport still yields >= 2 parts.
            String[] parts = line.split(" ", 4);
            if (parts.length >= 2) {
                keys.add(new String[]{parts[0], parts[1], parts.length >= 3 ? parts[2] : "", parts.length >= 4 ? parts[3] : ""});
            }
        }
        return keys;
    }

    /** NWP-20261116-29: the toast for a REMOVE-FIDO2-KEY reply ("OK <stillEnrolled>", ERR-NOSESSION or ERR). The WHOLE
     *  first token is matched, and only a second token of exactly "false" means no key is left. "" is the daemon not
     *  answering: the vault write may still have committed, so the text says the key may or may not be gone and points
     *  at the list, which confirmRemoveKey reloads on every reply. NWP-20261127-02 adds the fresh-tap replies:
     *  ERR-NOKEY, ERR-WRONGKEY and ERR-NOTSTORED. Anything else (ERR, BUSY, an unknown code) is a failure the user can
     *  retry. */
    static String removeText(String r) {
        String[] t = (r == null ? "" : r).trim().split("\\s+");
        String first = t[0];
        if (first.equals("OK")) {
            return t.length >= 2 && t[1].equals("false") ? "Key removed — passphrase only now" : "Key removed";
        }
        if (first.equals("ERR-NOSESSION")) return "This session has ended — sign in again to manage your keys.";
        // NWP-20261127-02: a removal needs a fresh tap over USB-C. ERR-NOKEY is every removal the USB-C path cannot
        // serve (no key answered, or the remaining keys answer only by NFC); ERR-WRONGKEY is a tap of a key that
        // cannot confirm it (the key being removed while others remain, or a key this profile does not hold).
        if (first.equals("ERR-NOKEY")) return "Plug in one of your keys to remove a key.";
        if (first.equals("ERR-WRONGKEY")) return "That key can't confirm this. Use one of your other keys.";
        if (first.equals("ERR-NOTSTORED")) return "This profile isn't stored, so it has no security keys to remove.";
        if (first.isEmpty()) {
            return "The phone didn't answer, so the key may or may not have been removed. "
                    + "The list below shows the keys that are still added.";
        }
        return "Couldn't remove the key — try again";
    }

    /** NWP-20261119-11: the text for a reply that can follow a committed key write (no answer, a closed socket). The
     *  caller re-renders the screen for it, so loadEnrolledKeys shows whether the key landed. */
    static final String ENROLL_MAY_HAVE_ADDED =
            "The phone didn't answer, so the key may have been added. Check the list below before you sign out.";
    private static final String ENROLL_BUSY = "The phone is busy saving. Nothing changed — try again in a minute.";
    private static final String ENROLL_FAILED = "Couldn't enroll — is the key plugged into the USB-C port? Try again.";
    private static final String ENROLL_START_OVER =
            "The second tap didn't complete — tap the button and enroll again from the start.";

    /** NWP-20261119-11: the text for an ENROLL-FIDO2 reply; null for OK (the caller shows its success screen). The WHOLE
     *  trimmed reply is matched. "" is no answer: the arm's deadline can fire after the vault write committed, so the
     *  text says the key may have been added. BUSY is the dispatcher's. ERR and any unknown code can be retried. */
    static String enrollText(String reply) {
        String t = reply == null ? "" : reply.trim();
        if (t.equals("OK")) return null;
        if (t.isEmpty()) return ENROLL_MAY_HAVE_ADDED;
        if (t.equals("ERR-NOTSTORED")) return "Save this profile to your store first, then add a key.";
        if (t.equals("BUSY")) return ENROLL_BUSY;
        if (t.equals("ERR-NOSESSION")) return "This session isn't signed in to a saved profile — sign in again to add a key.";
        return ENROLL_FAILED;
    }

    /** NWP-20261119-11: the text for a failed FIDO2-NFC-ENROLL-FINISH (NfcFido2.run's detail). "nfc-io" (a read timeout
     *  or a dead socket) and "closed" (the daemon closed without a reply) can follow a committed write, so they say the
     *  key may have been added. nfc-link-lost (the tag failed, so the assertion never completed) and every other detail
     *  mean start again. */
    static String nfcFinishText(String detail) {
        String t = detail == null ? "" : detail.trim();
        if (t.equals("BUSY")) return ENROLL_BUSY;
        if (t.equals("nfc-io") || t.equals("closed")) return ENROLL_MAY_HAVE_ADDED;
        return ENROLL_START_OVER;
    }
}
