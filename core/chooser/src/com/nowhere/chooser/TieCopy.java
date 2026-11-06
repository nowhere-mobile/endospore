package com.nowhere.chooser;

/** NWP-20261112-02: what the Tie screen (ProfileActivity.showPhoneTie, its OK UNTIED screen) says and asks before it
 *  ties, per the 2026-10-22 entry in docs/product-decisions.md, "the tie screen says a reset, lost or broken phone
 *  leaves only the 12 words, and asks for them to be written down before it ties". A tied profile needs this phone's
 *  security chip, a wipe or factory reset deletes the chip's key, and from then on only the 12-word recovery code
 *  opens it. Both strings are the decision's, byte for byte; they live here, pure java.lang, so a javac suite
 *  (test-tie-copy-java.sh) can pin them. maySend is the click's rule, read at the click and not only through the
 *  button's enabled state, because runTieVerb re-enables its buttons on every reply. An untie never asks.
 *  NWP-20261119-23: it also holds the Tie screen's read cap (READ_MS) and its words for every reply (failText). */
final class TieCopy {
    private TieCopy() {}

    /** The fourth "What it costs" point on the Tie screen. */
    static final String COST_RESET = "• If this phone is reset, lost or broken, your 12-word recovery code is the "
            + "only way back in. Without it, no one can open this profile again, including us.";

    /** The confirmation the Tie screen asks for before it ties. */
    static final String CONFIRM = "I have my 12-word recovery code written down";

    /** Whether the Tie screen may send verb: SE-TIE only once confirmed; every other verb (an untie) never asks. */
    static boolean maySend(String verb, boolean confirmed) {
        return !"SE-TIE".equals(verb) || confirmed;
    }

    /** NWP-20261119-23: how long the Tie screen reads SE-TIE / SE-UNTIE, in milliseconds. It outlasts the daemon's
     *  deadline in core/agent/se_tie.go handleSETie, conn.SetDeadline(seTieSlotWait + 10*time.Minute) = 60 s + 10 min,
     *  by 30 s for the connect and the reply. test-tie-copy-java.sh reads both daemon numbers and fails when this does
     *  not outlast them. */
    static final int READ_MS = 690_000;

    /** NWP-20261119-23: what the Tie screen says for a reply that is not OK, matched on the whole trimmed reply. No
     *  answer is not a failure: the daemon may still be tying, so that line says it may still finish. */
    static String failText(String reply) {
        String r = reply == null ? "" : reply.trim();
        if ("ERR-PASS".equals(r)) return "that isn't this profile's passphrase";
        if ("ERR-WORKER-BUSY".equals(r)) return "your profile is being saved — try again in a minute";
        if ("ERR-NOCREDIT".equals(r)) return "your storage plan doesn't have room to save your data again under the chip, "
                + "so nothing changed";
        if ("BUSY".equals(r)) return "your profile is busy saving — try again in a minute. Nothing changed.";
        if (r.isEmpty()) return "The phone didn't answer in time, so this may still finish. Showing where it stands now "
                + "— open this screen again in a few minutes.";
        return "Couldn't change it — showing where it stands";
    }
}
